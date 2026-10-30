# Backup System

Encrypted incremental backups use [restic](https://restic.net/). Ordinary
application PVCs use [Volsync](https://volsync.readthedocs.io/); PostgreSQL uses
native logical dumps before restic, **not a live PGDATA/PVC copy**.

## Architecture

```text
Application PVC ── Volsync/restic ───────────────┐
PostgreSQL ── logical dump ── local staging ── restic ── NFS ── NAS sync ── Backblaze B2
                                              └──── encrypted repositories ────┘
```

Restic deduplicates content before client-side encryption. Only encrypted restic
repository data is written to NFS; PostgreSQL plaintext dumps stay on the local
staging PVC. NFS is `192.168.20.106:/mnt/HDD/k8s/backups`.

Volsync mover pods mount application PVCs read-only (`copyMethod: Direct`) and
mount their individual NFS repository at `/mnt/backup`. Each backup target has
an isolated repository, so locks do not block unrelated repositories. The
repositories share the escrowed `volsync-restic` encryption password.

The NAS is intended to sync these encrypted repositories to Backblaze B2.
**Offsite recovery depends on verifying that NAS-to-Backblaze job**, its retained
copies, access credentials and encryption keys; Git alone cannot recover data.

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Volsync operator | `core` chart (`volsync-system` ns) | Runs mover pods on schedule |
| Restic secret | `shared` ns, reflected to all namespaces except `mission-control-agents` | Single encryption password + repo path |
| Reflector | `reflector` ns | Copies `volsync-restic` secret to all namespaces except `mission-control-agents` |
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
├── postgres-logical/   ← PostgreSQL logical dumps, encrypted by restic
├── postgres/           ← archived raw-PVC snapshots; not validated DB recovery
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
`volsync-restic` secret to all other namespaces except `mission-control-agents` automatically.

The secret is created by: `charts/shared/templates/backups.yaml`

> **WARNING**: If the `volsync-restic` secret in the `shared` namespace is
> deleted, a new password will be generated and **all existing backups become
> permanently unreadable** unless the original password is escrowed. Save it
> outside the cluster before relying on backups.

### Initial setup and escrow

1. Deployment generates the password once in `shared`, reflects it to permitted
   namespaces, and initializes each repository on its first backup.
2. Transfer the password directly to a password manager or an encrypted offline
   escrow through an approved secret-management workflow. Do not print it to a
   terminal, put it in shell history, logs, or Git.
3. Escrow the **full Sealed Secrets controller private-key set**, application
   encryption/signing secrets needed to read restored data (not just database
   passwords), and external storage/access credentials separately. Test access
   to escrow without depending on the failed cluster.

See [disaster-recovery.md](disaster-recovery.md) for recovery prerequisites.

## Shared and monitoring backups

Infrastructure backups are configured in:

- `charts/shared/values.yaml` → `resources.backups.sources` (Pi-hole)
- `charts/shared/values.yaml` → `resources.backups.postgresLogical` (PostgreSQL)
- `charts/monitor/values.yaml` → `backups.sources` (Grafana)

### PostgreSQL logical backups

The `shared/postgres-backup` CronJob runs daily at **03:00 UTC**. Jobs do not
overlap (`Forbid`), do not retry failed executions, and never restart containers.
Its PostgreSQL 18 dump init container connects with TLS to the primary service
and writes to a **20Gi local-path staging PVC**, with no NFS mount. It exports:

- `globals.sql`: roles (including password hashes) and global objects, using
  `pg_dumpall --globals-only --clean --if-exists`.
- `bootstrap-role.json`: source bootstrap role identity (OID 10), required to
  preserve PostgreSQL role grantors during recovery.
- `databases.list`: NUL-delimited `oid<TAB>database-name` records for every
  connectable non-template database, including `postgres`.
- `databases/<oid>/`: uncompressed directory-format `pg_dump` archives preserving
  ownership, ACLs and large objects.
- `complete`: published only after every export succeeds.

The completed generation is `/backup/current`; incomplete work is never uploaded.
At most the prior complete generation plus new working output are staged; stale
failed work is reset on the next run. The local staging PVC contains sensitive
plaintext, including role hashes: protect host/storage access and do not copy it
to NFS. Provision enough space for the prior and new generation.
The 20Gi PVC size is a provisioning request, **not an enforced local-path disk
quota**. Monitor free space on the backing host disk; staging must remain on
local-path rather than NFS.

Only after dumping succeeds does the restic container mount staging read-only
and upload `/backup/current` with host `postgres-cluster`. It mounts the NFS
parent at `/mnt/backup` but overrides the repository to
`/mnt/backup/postgres-logical`, separate from old `/postgres` snapshots.
It initializes only an absent repository; wrong passwords, corruption and lock
errors fail the Job rather than unlocking or recreating the repository.
After a successful snapshot it retains **7 daily, 4 weekly and 3 monthly**
snapshots and prunes unreferenced data.

The first real upload was OOM-killed at 512Mi. The uploader now bounds Go
parallelism with `gomaxprocs: 2` and uses `goMemoryLimit: 384MiB` beneath that
hard limit; verify actual peak memory during production acceptance. Keep the
Go target below the hard limit when changing resource settings. It is a soft
target, not itself a guarantee against OOM.

Each database dump is internally consistent, but different databases are **not
one atomic cross-database point in time**. There is no WAL archive, Barman or
PITR: RPO is up to 24 hours when scheduled jobs succeed, longer after failures.
The old raw-PVC `/postgres` repository is retained without deletion, but is
**not a validated PostgreSQL recovery source**. No new generic PGDATA backup
should be enabled.

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

For PostgreSQL, inspect `kubectl get cronjob,jobs -n shared` and the
`postgres-backup` Job outcome. A successful dump alone is not an off-cluster
backup: confirm a new `postgres-logical` snapshot, repository integrity and the
NAS offsite copy. Avoid dumping logs or payload/credential-bearing SQL during
investigation.

## Restoring a single PVC

This procedure is for ordinary application PVCs only, **not PostgreSQL**. Stop
the owning application and prevent GitOps from restarting it before overwriting
its data. PostgreSQL requires the isolated logical restore in
[disaster-recovery.md](disaster-recovery.md#step-6b-restore-postgresql-in-isolation).

### Prerequisites

- The escrowed restic password, supplied through a protected password file
- Access to the NFS share (or a copy of it)
- `restic` CLI installed locally

### Step 1: List available snapshots

```bash
# Populate this mode-0600 file from escrow without printing its contents.
export RESTIC_PASSWORD_FILE=/secure/escrow/restic-password

# Select one repository, not the NFS parent directory.
export RESTIC_REPOSITORY=/mnt/backups/pihole
restic snapshots
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
            path: /mnt/HDD/k8s/backups/pihole
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

export RESTIC_REPOSITORY=/mnt/backups/pihole
export RESTIC_PASSWORD_FILE=/secure/escrow/restic-password

# Browse a snapshot interactively
restic mount /mnt/restic-browse

# Choose an explicit snapshot ID after inspecting the repository.
restic restore <snapshot-id> --target /secure/local-restore
```

Then copy the restored data into the PVC using `kubectl cp` or by mounting it.

## Full disaster recovery

See [disaster-recovery.md](disaster-recovery.md) for the complete procedure covering K3s installation, ArgoCD bootstrap, secret restoration, and data recovery.

## What is NOT backed up

- **Prometheus metrics** (50Gi) — time-series data that regenerates from
  scraping. Only historical data is lost.
- **Alertmanager state** (10Gi) — transient alert routing state.

## Backup schedule overview

| Namespace | Source | Schedule |
|-----------|--------|----------|
| shared | pihole-data (Volsync) | 02:00 daily |
| shared | PostgreSQL logical dump + restic | 03:00 UTC daily |
| monitoring | grafana (Volsync) | 02:00 daily |

Schedules are staggered to avoid NFS contention. PostgreSQL retention is
7 daily / 4 weekly / 3 monthly.

### Recovery validation status

The local PostgreSQL 18/restic regression exercises backup, regenerated-dump
deduplication, full restore, owners/ACLs, membership grantors, sequences, large
objects, unusual database names and failure guards against disposable containers:

```bash
python3 repos/core/charts/shared/tests/postgres_backup_test.py
```

It requires Docker and image-pull access, publishes no ports, and cleans up its
own fixtures. It does not verify production TLS, NAS permissions or offsite copies.

The live isolated restore drill is **pending**. No measured production restore
success, compression ratio, or RTO is claimed. A drill must verify globals,
database contents, owners/ACLs, large objects, extensions and application-level
behavior, plus offsite retrieval and escrow access, before relying on recovery.

### Updating reflection annotations without rotating the password

The generator-backed ExternalSecret has `refreshInterval: "0"`. ESO skips
refresh while existing Secret data is valid, including after template edits.
When changing reflection annotations, first reconcile the template through
GitOps, then update only the existing source Secret metadata to match. Never
force-sync, delete the source Secret, or change its data: that can generate a
new password and make existing backups inaccessible. Record the metadata-only
patch and verify source identity, unchanged data, and backup consumer health
in the Mission Control task.
