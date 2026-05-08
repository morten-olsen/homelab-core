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

Each backup target gets its own **isolated restic repository** at
`/backup/<name>` (via per-app NFS subdirectory mounts). This eliminates lock
contention between backups — a stale lock in one app's repo cannot block any
other app's backups. All repos share the same encryption password.

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

Each backup target has its own restic repository in a subdirectory:

```
/mnt/HDD/k8s/backups/
├── pihole/             ← independent restic repo
│   ├── config
│   ├── data/
│   ├── index/
│   ├── keys/
│   ├── locks/          ← only affects this app
│   └── snapshots/
├── grafana/
├── forgejo/
└── ...
```

Each mover pod mounts its app-specific subdirectory at `/mnt/backup`, so the
`RESTIC_REPOSITORY: /mnt/backup` path in the shared secret works for all apps
without per-app secrets.

### Auto-creation of NFS subdirectories

The NFS server only exports `/mnt/HDD/k8s/backups`; per-app subdirectories
under it must exist before a mover pod can mount one. A Kyverno
`ClusterPolicy` (`backup-nfs-mkdir`, defined in
`charts/shared/templates/backup-mkdir-policy.yaml`) handles this
automatically:

- On `ReplicationSource` admission, Kyverno generates a one-shot Job in
  the same namespace that mounts the parent NFS path and runs
  `mkdir -p /mnt/backup/<release>-<pvc>`.
- The Job is one-shot (`synchronize: false`) and self-cleans via
  `ttlSecondsAfterFinished: 600`.
- The kubelet's volume-mount retry then succeeds on its next attempt
  (~1m), so the mover pod recovers without manual intervention.

If the policy is disabled (`resources.backups.autoMkdir.enabled: false`),
operators must `mkdir` each subdirectory on the NAS by hand before the
first mover run, otherwise the mover pod gets stuck in `Init:0/2` with
`mount.nfs: ... failed, reason given by server: No such file or directory`.

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

See [disaster-recovery.md](disaster-recovery.md) for the complete procedure covering K3s installation, ArgoCD bootstrap, secret restoration, and data recovery.

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
