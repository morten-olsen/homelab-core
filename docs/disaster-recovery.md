# Disaster Recovery

Complete procedure to rebuild the cluster from scratch and restore all data. Covers everything from bare metal to a fully operational cluster.

## Prerequisites

Before you need this guide, ensure these are saved outside the cluster:

| Item | Where to save | How to export |
|------|---------------|---------------|
| Restic password | Password manager | `kubectl get secret volsync-restic -n shared -o jsonpath='{.data.RESTIC_PASSWORD}' \| base64 -d` |
| Cloudflare API token | Password manager | Manual -- same token used for DNS zone |
| Registry credentials | Password manager | Username + password for zot.olsen.cloud (if using private registry) |
| YubiKey | Physical possession | Used for SOPS decryption of `secrets/unifi.yaml` |
| Backup age key | Offline storage (USB/printed) | Created during `scripts/setup-secrets.sh` |

The Git repositories and NFS backups (`192.168.20.106:/mnt/HDD/k8s/backups`) contain everything else.

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

If using a private OCI registry (zot), configure the mirror:

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

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.33.4+k3s1" sh -s - \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --kubelet-arg="config=/etc/rancher/k3s/kubelet.config"
```

- `--disable traefik` and `--disable servicelb` — Istio handles ingress
- `--kubelet-arg="config=..."` — applies the max pods limit
- K3s includes local-path storage provisioner and CoreDNS by default

### Copy kubeconfig to workstation

```bash
scp root@192.168.20.180:/etc/rancher/k3s/k3s.yaml ~/.kube/config
# Edit the server address from 127.0.0.1 to 192.168.20.180
sed -i '' 's/127.0.0.1/192.168.20.180/' ~/.kube/config
```

Verify:

```bash
kubectl get nodes
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
  --version 9.4.15 \
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

Save the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## Step 3: Create the Cloudflare API token secret

This must exist before the shared chart deploys, or cert-manager won't be able to issue the wildcard TLS certificate:

```bash
kubectl create namespace shared
kubectl create secret generic cloudflare-api-token -n shared \
  --from-literal=CLOUDFLARE_API_TOKEN='<your-token>'
```

## Step 4: Restore the restic password

The External Secrets Operator (deployed in the next step) will try to generate a new password. Pre-create the secret with the saved password so existing backups can be decrypted:

```bash
kubectl create secret generic volsync-restic -n shared \
  --from-literal=RESTIC_REPOSITORY=/mnt/backup \
  --from-literal=RESTIC_PASSWORD='<your-saved-password>'
```

Reflector (deployed in the next step) will automatically copy this to all namespaces. The ExternalSecret has `refreshInterval: "0"`, so it will not overwrite the secret once it exists.

## Step 5: Deploy the homelab chart

This deploys the master chart which creates ArgoCD Applications for the three deployment waves: core operators (wave 0), shared infrastructure (wave 1), and monitoring (wave 2).

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

## Step 6: Restore infrastructure PVCs

Scale down workloads that own the PVCs, then restore from backup:

```bash
# Scale down to release PVC locks
kubectl scale deploy pihole -n shared --replicas=0
kubectl scale cluster postgres -n shared --replicas=0 2>/dev/null || true

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
            path: /mnt/HDD/k8s/backups
EOF

# Restore PostgreSQL
cat <<EOF | kubectl apply -f -
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: restore-postgres
  namespace: shared
spec:
  trigger:
    manual: restore-once
  restic:
    repository: volsync-restic
    destinationPVC: postgres-cluster-1
    copyMethod: Direct
    moverSecurityContext:
      runAsUser: 0
      runAsGroup: 0
    moverVolumes:
      - mountPath: backup
        volumeSource:
          nfs:
            server: 192.168.20.106
            path: /mnt/HDD/k8s/backups
EOF
```

Wait for restores, then scale back up:

```bash
kubectl get replicationdestination -n shared -w
# Wait until lastManualSync shows "restore-once"

kubectl scale deploy pihole -n shared --replicas=1
# Postgres will be managed by CloudNative-PG operator automatically
```

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
            path: /mnt/HDD/k8s/backups
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
            path: /mnt/HDD/k8s/backups
EOF

kubectl get replicationdestination -n prod -w
kubectl scale deploy <app> -n prod --replicas=1
```

## Step 9: Clean up and verify

```bash
# Remove all restore resources
kubectl delete replicationdestination --all -A

# Verify all pods are running
kubectl get pods -A | grep -v Running | grep -v Completed

# Verify backup schedules are active
kubectl get replicationsource -A

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

## Recovery time estimate

| Phase | Duration |
|-------|----------|
| K3s install | 5 min |
| ArgoCD + operators | 10 min |
| Infrastructure restore (pihole, postgres, grafana) | 15 min |
| App deployment + critical restores | 30-60 min |
| **Total** | **~1-1.5 hours** |

The cluster is functional (with empty app data) after ~15 minutes. Full data restoration depends on backup sizes and NFS throughput.
