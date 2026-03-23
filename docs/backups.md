# Backup System

Encrypted incremental backups for all Kubernetes persistent volumes, powered by
[Volsync](https://volsync.readthedocs.io/) and [restic](https://restic.net/).

## Architecture

```
┌─────────────────┐     restic (encrypted,     ┌──────────────┐     automatic     ┌───────────┐
│  PVC (source)   │──── incremental, dedup) ───▶│  NFS Share   │────────────────▶  │ Backblaze │
│  local-path     │     via Volsync mover pod   │  192.168.20  │                   │   B2      │
└─────────────────┘                             │  .106        │                   └───────────┘
                                                └──────────────┘
```

Each PVC with backup enabled gets a `ReplicationSource` CR. Volsync runs a restic
mover pod on the configured schedule that:

1. Mounts the source PVC (read-only via `copyMethod: Direct`)
2. Mounts the NFS share at `/backup` via `moverVolumes`
3. Runs `restic backup` against the PVC data, writing encrypted incremental
   snapshots to `/backup/`
4. Runs `restic forget` + `restic prune` per the retention policy

All backups across all namespaces share a **single restic repository** at
`/backup`. Snapshots are scoped by hostname (the ReplicationSource name), so
each PVC's backups are independently addressable. This gives maximum
deduplication and requires only one encryption password for the entire cluster.

The NFS share content is then automatically backed up to Backblaze B2, providing
offsite redundancy.

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Volsync operator | `core` chart (`volsync-system` ns) | Runs mover pods on schedule |
| Restic secret | `shared` ns, reflected to all namespaces | Single encryption password + repo path |
| Reflector | `reflector` ns | Copies `volsync-restic` secret to all namespaces |
| ReplicationSource | Per PVC | Defines what/when/how to back up |
| NFS share | `192.168.20.106:/mnt/HDD/k8s/backups` | Backup storage target |

### NFS layout

All backups write to a single restic repository at the NFS mount root:

```
/mnt/HDD/k8s/backups/
├── config          ← restic repo metadata
├── data/           ← deduplicated encrypted chunks
├── index/          ← restic index files
├── keys/           ← restic key file
├── locks/          ← lock files during operations
└── snapshots/      ← snapshot metadata (tagged by hostname)
```

Snapshots are identified by their hostname, e.g., `backup-pihole`,
`backup-grafana`, etc.

## Restic password

A single restic encryption password is generated automatically in the `shared`
namespace via an External Secrets Password generator with `refreshInterval: "0"`
(generated once, never rotated). The Reflector operator copies the
`volsync-restic` secret to all other namespaces automatically.

The secret is created by: `charts/shared/templates/backups.yaml`

> **WARNING**: If the `volsync-restic` secret in the `shared` namespace is
> deleted, a new password will be generated and **all existing backups become
> permanently unreadable**. Export and save the password immediately after first
> deploy (see below).

### Initial setup

1. Deploy. Volsync, External Secrets, and Reflector will automatically:
   - Generate the restic password in `shared`
   - Reflect it to all other namespaces
   - Initialise the restic repository on first backup run

2. **Export and save the password** — this is critical for disaster recovery:
   ```bash
   kubectl get secret volsync-restic -n shared \
     -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d
   ```

3. Store the password in a password manager or other secure offline location.

## Shared and monitoring backups

Backups for infrastructure PVCs (pihole, postgres, grafana) are configured
directly in the core chart values:

- `charts/shared/values.yaml` → `resources.backups.sources`
- `charts/monitor/values.yaml` → `backups.sources`

Each source specifies the PVC name, schedule, and retention.

### Disabling backups

Set `enabled: false`:

```yaml
# In shared/values.yaml
resources:
  backups:
    enabled: false

# In monitor/values.yaml
backups:
  enabled: false
```

## Adding backup to a new namespace

No extra setup is needed. Reflector automatically copies the `volsync-restic`
secret to every namespace. Just create `ReplicationSource` resources that
reference `volsync-restic` and include the standard `moverVolumes` NFS mount.

## Monitoring backups

Check ReplicationSource status:

```bash
# List all backup sources and their last sync
kubectl get replicationsource -A

# Detailed status for a specific backup
kubectl describe replicationsource backup-pihole -n shared
```

Key fields to check:
- `status.lastSyncTime` — when the last backup completed
- `status.lastSyncDuration` — how long it took
- `status.conditions` — any errors

## Restoring a single PVC

### Prerequisites

- The restic password (export from the cluster or use the saved copy)
- Access to the NFS share (or a copy of it)
- `restic` CLI installed locally

### Step 1: List available snapshots

```bash
# Get the password from the cluster (if still running)
export RESTIC_PASSWORD=$(kubectl get secret volsync-restic -n shared \
  -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d)

# Mount the NFS share (or use the local path if already mounted)
export RESTIC_REPOSITORY=/path/to/nfs/mount

# List all snapshots (each ReplicationSource has its own hostname)
restic snapshots

# Filter by a specific backup
restic snapshots --host backup-pihole
```

### Step 2: Restore via Volsync ReplicationDestination

Create a `ReplicationDestination` to restore a PVC from the restic repo:

```yaml
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
```

```bash
kubectl apply -f restore.yaml
```

Monitor progress:

```bash
kubectl get replicationdestination restore-pihole -n shared -w
```

Once complete, delete the ReplicationDestination:

```bash
kubectl delete replicationdestination restore-pihole -n shared
```

### Alternative: Restore with restic CLI

If you prefer to restore manually (e.g., to inspect data before overwriting):

```bash
mount -t nfs 192.168.20.106:/mnt/HDD/k8s/backups /mnt/backups

export RESTIC_REPOSITORY=/mnt/backups
export RESTIC_PASSWORD='your-restic-password'

# Browse a snapshot interactively
restic mount /mnt/restic-browse

# Or restore a specific snapshot to a local directory
restic restore latest --host backup-pihole --target /tmp/restore
```

Then copy the restored data into the PVC using `kubectl cp` or by mounting it.

## Full disaster recovery

Complete procedure to rebuild the cluster and restore all data from backups.

### Prerequisites

- The exported restic password (from your password manager)
- Access to the NFS share at `192.168.20.106:/mnt/HDD/k8s/backups`
  (or the Backblaze B2 copy)
- The Git repositories

### Step 1: Rebuild the cluster

Follow the standard cluster bootstrap procedure to get a running k3s cluster
with ArgoCD.

### Step 2: Deploy infrastructure

Deploy the core chart first to get all operators running:

```bash
cd core/charts/homelab
helm template . | kubectl apply -f -
```

Wait for all operators to be ready, especially:
- Volsync (`volsync-system` namespace)
- CloudNative-PG (`cloudnative-pg` namespace)
- External Secrets (`external-secrets` namespace)
- Reflector (`reflector` namespace)

```bash
kubectl wait --for=condition=available deployment -n volsync-system --all --timeout=300s
```

### Step 3: Restore the restic password

The External Secrets Password generator will create a NEW password on a fresh
cluster. You must replace it with the saved password so existing backups can be
decrypted.

Create the secret in the `shared` namespace **before** ArgoCD creates the
ExternalSecret (or delete and recreate after):

```bash
kubectl create namespace shared 2>/dev/null || true
kubectl create secret generic volsync-restic -n shared \
  --from-literal=RESTIC_REPOSITORY=/mnt/backup \
  --from-literal=RESTIC_PASSWORD='<your-saved-password>'
```

Reflector will automatically copy this to all other namespaces. Since
`refreshInterval: "0"` is set on the ExternalSecret, it will not overwrite the
secret once it exists.

### Step 4: Restore infrastructure PVCs

```bash
# Restore pihole data
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

# Restore postgres data
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

Wait for restores to complete:

```bash
kubectl get replicationdestination -n shared -w
```

### Step 5: Restore Grafana

```bash
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
```

### Step 6: Restore app PVCs

See the apps repository documentation for app-specific restore procedures.

### Step 7: Clean up

Delete all ReplicationDestination resources after restores complete:

```bash
kubectl delete replicationdestination --all -A
```

### Step 8: Verify

- Check that all apps are running and accessible
- Verify data integrity in critical apps
- Confirm backup schedules are running:
  ```bash
  kubectl get replicationsource -A
  ```

## What is NOT backed up

- **Prometheus metrics** (50Gi) — time-series data that regenerates from
  scraping. Only historical data is lost.
- **Alertmanager state** (10Gi) — transient alert routing state.

## Backup schedule overview

| Namespace | PVCs | Schedule |
|-----------|------|----------|
| shared | pihole-data | 02:00 daily |
| shared | postgres-cluster-1 | 03:00 daily |
| monitoring | grafana | 02:00 daily |

Schedules are staggered to avoid NFS contention.
