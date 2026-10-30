# Disaster Recovery

Procedure to bootstrap the host and recover data. The live PostgreSQL isolated
restore drill is **pending**; this guide is not evidence of a successful full
recovery or a measured RTO.

## Prerequisites

Before you need this guide, escrow these outside the cluster using a password
manager or encrypted offline storage. Transfer secrets directly into protected
files or approved secret-management tooling; never print them to the terminal,
paste them into command arguments/history, or commit them to Git.

| Item | Recovery requirement |
|------|----------------------|
| Original restic password | Decrypt all retained repositories; protect a password file with mode 0600 |
| Full Sealed Secrets controller private-key set | Unseal existing Git-managed secrets; a new controller key cannot decrypt old ciphertext |
| Application encryption/signing secrets | Read encrypted application data and restore identity/session integrations; DB contents alone are insufficient |
| Cloudflare API token | DNS/certificate access |
| Registry and Git credentials | Retrieve private images and GitOps sources |
| NAS and Backblaze credentials and keys | Retrieve offsite repositories, including any NAS-side encryption key |

Git stores configuration, **not everything needed for recovery**. Verify the NAS
job actually copies `192.168.20.106:/mnt/HDD/k8s/backups` to Backblaze, confirm a
recent offsite copy is readable, and test escrow access independently of the
cluster. PostgreSQL plaintext staging is local-path only and is not an offsite
copy. The new encrypted repository is `postgres-logical`; archived `/postgres`
raw snapshots are retained but are not a validated database recovery source.

## Step 1: Install and configure K3s

SSH into the host (192.168.20.180).

### Kubelet configuration

Create the kubelet config to raise the max pod limit from the default 110:

```bash
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/kubelet.config <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 250
EOF
```

### Private registry mirror (optional)

If using a private OCI registry (zot), configure the mirror. Create the actual
file using a protected editor or secret-management tool and restrict it to mode
0600; never substitute real passwords into a shell here-document or terminal
transcript. This example shows structure only:

```bash
cat > /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  zot.local:
    endpoint:
      - https://zot.olsen.cloud
configs:
  zot.local:
    auth:
      username: <registry-username>
      password: <registry-password>
  zot.olsen.cloud:
    auth:
      username: <registry-username>
      password: <registry-password>
EOF
```

### Install K3s

All server flags go in `/etc/rancher/k3s/config.yaml`, so re-running the
installer (upgrades) cannot drop them:

```bash
cat > /etc/rancher/k3s/config.yaml <<'EOF'
disable:
  - traefik
kubelet-arg:
  - allowed-unsafe-sysctls=net.ipv4.*
  - config=/etc/rancher/k3s/kubelet.config
EOF
chmod 600 /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.37.1+k3s1" sh -
```

- Only Traefik is disabled: Istio handles ingress, but ServiceLB exposes the
  gateway, Forgejo SSH, MQTT and Pi-hole DNS, and the bundled local-path
  provisioner backs the PVCs.
- `kubelet-arg` applies the max pods limit and allows the `net.ipv4.*` pod
  sysctls.
- Host-level settings outside this chart (kernel sysctls, disks and the CI disk
  marker, `/etc/hosts` pins, the API server's OIDC authentication config) are
  recorded with the host in the operations repository (`docs/host-setup.md`);
  apply them as part of this step.

### Add the cluster to your kubeconfig

Do not copy `k3s.yaml` over `~/.kube/config`; that destroys other contexts.
Merge the cluster and user from the host's `/etc/rancher/k3s/k3s.yaml`, with
the server address changed from `127.0.0.1` to `192.168.20.180`:

```bash
scp root@192.168.20.180:/etc/rancher/k3s/k3s.yaml /tmp/k3s.yaml
sed -i '' 's/127.0.0.1/192.168.20.180/' /tmp/k3s.yaml
KUBECONFIG=~/.kube/config:/tmp/k3s.yaml kubectl config view --flatten > /tmp/merged && \
  mv /tmp/merged ~/.kube/config && rm /tmp/k3s.yaml
```

When `default` entries already exist, the existing file wins on conflicts;
replace the `default` user's certificate fields by hand instead.

Verify:

```bash
kubectl --context default get nodes
# Should show: compute   Ready   control-plane,master
kubectl get node compute -o jsonpath='{.status.capacity.pods}'
# Should show: 250
```

## Step 2: Install ArgoCD

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 10.9.0 \
  --set configs.params.server.insecure=true \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30080 \
  --set server.service.nodePortHttps=30443 \
  --set repoServer.livenessProbe.timeoutSeconds=10 \
  --set repoServer.livenessProbe.initialDelaySeconds=30 \
  --set repoServer.readinessProbe.timeoutSeconds=10 \
  --wait \
  --timeout 10m

kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
```

Retrieve the initial ArgoCD admin password through the approved secret workflow
directly into a password manager, without displaying it in a terminal or logs.

## Step 3: Create the Cloudflare API token secret

This must exist before the shared chart deploys, or cert-manager cannot issue the
wildcard certificate. Place the escrowed token in a protected file using secret
tooling, then create the Secret without putting the value in shell arguments:

```bash
kubectl create namespace shared
kubectl create secret generic cloudflare-api-token -n shared \
  --from-file=CLOUDFLARE_API_TOKEN=/secure/escrow/cloudflare-api-token
```

## Step 4: Restore the restic password

Pre-create the Secret with the **original** password before External Secrets can
generate a replacement. Supply an escrowed mode-0600 file, not a literal value:

```bash
kubectl create secret generic volsync-restic -n shared \
  --from-literal=RESTIC_REPOSITORY=/mnt/backup \
  --from-file=RESTIC_PASSWORD=/secure/escrow/restic-password
```

Reflector copies it to permitted namespaces. The ExternalSecret has
`refreshInterval: "0"` and does not overwrite an existing valid Secret.
Separately restore the Sealed Secrets controller's full escrowed key set using
its recovery procedure **before reconciling sealed application secrets**.
Preserve application encryption secrets; do not generate replacements and assume
the restored data will remain readable.

## Step 5: Deploy the homelab chart

This deploys the master chart which creates ArgoCD Applications for the three deployment waves: core operators (wave 0), shared infrastructure (wave 1), and monitoring (wave 2).

Keep dependent applications stopped and prevent ArgoCD self-heal from restarting
them until their databases and volumes have been restored and validated. Do not
let new empty-database writes or scheduled backups replace recovery evidence.

```bash
cd repos/core/charts/homelab
helm template homelab . | kubectl apply -f -
```

ArgoCD will now reconcile all three waves. Watch progress:

```bash
kubectl get applications -n argocd -w
```

Wait for critical operators before proceeding:

```bash
kubectl wait --for=condition=available deployment -n volsync-system --all --timeout=300s
kubectl wait --for=condition=available deployment -n cloudnative-pg --all --timeout=300s
kubectl wait --for=condition=available deployment -n external-secrets --all --timeout=300s
kubectl wait --for=condition=available deployment -n reflector --all --timeout=300s
```

## Step 6a: Restore Pi-hole

Stop the owning workload and suspend its GitOps reconciliation for the restore.
This is an ordinary file-PVC restore, not a PostgreSQL recovery procedure:

```bash
# Scale down to release PVC locks
kubectl scale deploy pihole -n shared --replicas=0

# Restore Pi-hole
cat <<EOF | kubectl apply -f -
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: restore-pihole
  namespace: shared
spec:
  trigger:
    manual: restore-once
  restic:
    repository: volsync-restic
    destinationPVC: pihole-data
    copyMethod: Direct
    moverSecurityContext:
      runAsUser: 0
      runAsGroup: 0
    moverVolumes:
      - mountPath: backup
        volumeSource:
          nfs:
            server: 192.168.20.106
            path: /mnt/HDD/k8s/backups/pihole
EOF

```

Wait for the Pi-hole restore before restarting it:

```bash
kubectl get replicationdestination -n shared -w
# Wait until lastManualSync shows "restore-once"

kubectl scale deploy pihole -n shared --replicas=1
```

## Step 6b: Restore PostgreSQL in isolation

**Never restore raw files into the live CloudNativePG cluster or delete its
PVCs.** Do not use archived `/postgres` raw snapshots as a validated recovery
source. This procedure uses PostgreSQL-native logical exports, not Barman/PITR;
RPO is up to 24 hours when daily 03:00 UTC jobs succeed, and longer on failures.
Database dumps are individually consistent, not an atomic cross-database point.
Retention in `postgres-logical` is 7 daily / 4 weekly / 3 monthly.

1. On a trusted recovery host, mount the NFS backup parent (or retrieve its
   encrypted copy from verified Backblaze storage). Use the original escrowed
   password file and select a specific snapshot:

   ```bash
   export RESTIC_PASSWORD_FILE=/secure/escrow/restic-password
   export RESTIC_REPOSITORY=/mnt/backups/postgres-logical
   restic snapshots --host postgres-cluster --path /backup/current
   restic restore <snapshot-id> --target /secure/local-restore
   ```

   The target must be protected **local** storage, never NFS: restored SQL and
   directory archives are plaintext and contain role password hashes. Require
   `/secure/local-restore/backup/current/complete`, `globals.sql`,
   `bootstrap-role.json`, `databases.list` and all listed `databases/<oid>/` archives.

2. Provision a **fresh, isolated PostgreSQL 18** instance using the matching
   source image and required extensions. It must have no workload data and no
   connection to production application writers. Initialize it with the source
   bootstrap role name from `bootstrap-role.json` (`postgres` in this homelab).
   That role must retain **OID 10**: PostgreSQL treats it specially when restoring
   membership grantors. Create a separate uniquely named superuser, for example
   `homeit7_recovery_admin`, absent from the source, to perform the restore.
   The maintenance DB `recovery_control` must also be absent from the source.
   Use a protected pgpass file; do not put passwords in commands.

3. Run the following **Bash** on the isolated recovery host with matching
   PostgreSQL 18 client tools. Set `PGHOST`/`PGPORT` to the isolated instance
   explicitly, `PGUSER=homeit7_recovery_admin`, `PGDATABASE=recovery_control`,
   and `PGPASSFILE` to its protected authentication file. Confirm these resolve
   to the recovery instance, **not** `postgres-cluster-rw.shared.svc.cluster.local`.

   ```bash
   set -euo pipefail
   restore_root=/secure/local-restore/backup/current
   test -f "$restore_root/complete"
   python3 repos/core/charts/shared/files/postgres-backup/prepare-restore.py \
     "$restore_root" /secure/local-restore/globals.restore.sql
   createdb --owner="$PGUSER" recovery_control
   psql --no-psqlrc --single-transaction --set=ON_ERROR_STOP=1 \
     --file=/secure/local-restore/globals.restore.sql

   while IFS= read -r -d '' record; do
     oid=${record%%$'\t'*}
     case "$oid" in ''|*[!0-9]*) exit 1 ;; esac
     pg_restore --exit-on-error --clean --if-exists --create \
       --dbname=recovery_control "$restore_root/databases/$oid"
   done < "$restore_root/databases.list"
   ```

   `createdb` creates the maintenance DB once, owned by the recovery identity.
   `prepare-restore.py` makes a protected, restore-only globals copy: it omits
   exactly the source bootstrap role's DROP/CREATE statements, preserving every
   ALTER ROLE, password, setting and GRANT. It refuses ambiguous input or an
   existing output file. The prepared SQL checks the destination bootstrap name
   at OID 10 before applying changes; a mismatch fails without restoring roles.
   Do not edit grantors, add artificial ADMIN memberships, or ignore SQL errors.
   Restore every listed archive, **including `postgres`**, while connected to
   `recovery_control`; do not connect to a database being recreated. Do not
   suppress errors, disable ownership/ACL restoration, or continue after failure.

4. Validate database inventories, contents, owners, role membership, ACLs, large
   objects, extensions and application behavior against expected results. Test
   application encryption keys as well as database credentials. Keep application
   writers stopped until the data and cross-database relationships are accepted.
   Cutover to a replacement managed cluster is a separate controlled operation;
   this guide does not overwrite the existing CNPG instance automatically.

The live drill remains pending. Record observed outcomes and recovery timings
only after exercising this process, including retrieving the offsite copy.


## Step 7: Restore Grafana

```bash
kubectl scale deploy prometheus-operator-grafana -n monitoring --replicas=0

cat <<EOF | kubectl apply -f -
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: restore-grafana
  namespace: monitoring
spec:
  trigger:
    manual: restore-once
  restic:
    repository: volsync-restic
    destinationPVC: prometheus-operator-grafana
    copyMethod: Direct
    moverSecurityContext:
      runAsUser: 0
      runAsGroup: 0
    moverVolumes:
      - mountPath: backup
        volumeSource:
          nfs:
            server: 192.168.20.106
            path: /mnt/HDD/k8s/backups/grafana
EOF

# Wait, then scale back up
kubectl get replicationdestination -n monitoring -w
kubectl scale deploy prometheus-operator-grafana -n monitoring --replicas=1
```

## Step 8: Deploy applications

The apps and containarr ApplicationSets should already be deployed by ArgoCD if the app root charts are configured. If not:

```bash
# Check if apps are syncing
kubectl get applications -n argocd | grep -E 'apps-root|containarr-root'

# If missing, deploy them manually via ArgoCD or helm
```

Applications will start but their PVCs will be empty. Restore critical app data using the procedure in `repos/apps/docs/backups.md`. Priority order:

1. **vaultwarden** -- password vault
2. **forgejo** -- Git repositories
3. **home-assistant** -- automations and history
4. **immich** -- photos (upload + library PVCs)
5. Remaining apps as needed

Each app restore follows the same pattern:

```bash
kubectl scale deploy <app> -n prod --replicas=0

cat <<EOF | kubectl apply -f -
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: restore-<app>
  namespace: prod
spec:
  trigger:
    manual: restore-once
  restic:
    repository: volsync-restic
    destinationPVC: <app>-data    # check actual PVC name
    copyMethod: Direct
    moverSecurityContext:
      runAsUser: 0
      runAsGroup: 0
    moverVolumes:
      - mountPath: backup
        volumeSource:
          nfs:
            server: 192.168.20.106
            path: /mnt/HDD/k8s/backups/<app-repository>
EOF

kubectl get replicationdestination -n prod -w
kubectl scale deploy <app> -n prod --replicas=1
```

Replace `<app-repository>` with the exact per-PVC repository used by that
application's ReplicationSource; do not mount the NFS parent as a repository.
Keep applications stopped until their logical databases and file data have
both been validated.

## Step 9: Clean up and verify

```bash
# Remove all restore resources
kubectl delete replicationdestination --all -A

# Verify all pods are running
kubectl get pods -A | grep -v Running | grep -v Completed

# Verify backup schedules are active
kubectl get replicationsource -A
kubectl get cronjob postgres-backup -n shared

# Verify TLS certificate is issued
kubectl get certificate -n shared

# Verify ingress is working
curl -sk https://grafana.olsen.cloud/
```

## What is NOT backed up

These are regenerated automatically and do not need restoration:

- **Prometheus metrics** (50Gi) -- re-scraped from targets
- **Alertmanager state** (10Gi) -- transient routing state
- **Ollama models** -- re-downloaded on first use
- **Immich ML models** -- re-downloaded on startup
- **Cache directories** -- rebuilt automatically

## Recovery validation and timing

The live isolated PostgreSQL restore and complete disaster-recovery drill are
**pending**. No measured production restore success, compression savings or RTO
is claimed. Record actual bootstrap, offsite retrieval, database restore,
application validation and cutover durations during a drill. Recovery time
depends on data sizes, available images/extensions, storage throughput and
escrow access; a running cluster with empty data is not a completed recovery.
