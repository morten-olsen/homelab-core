# CI storage

Woodpecker workflow workspaces use the non-default `woodpecker-ci` class on
`compute`. The existing K3s local-path provisioner v0.0.37 handles both classes:
`local-path` stays on NVMe at `/var/lib/rancher/k3s/storage`, and `woodpecker-ci`
uses the `/mnt/ssd/woodpecker-ci` subfolder on the Samsung 870 QVO SATA SSD (`sda2`).
The SSD is a general disk: other workloads can use sibling folders under
`/mnt/ssd`. CI gets no exclusive disk allocation or filesystem quota.
The Woodpecker server and all existing app volumes stay on NVMe.

The host filesystem is shared ext4, label `homelab-ssd`, UUID `b8566ede-b661-4074-8b5a-f2dc743d6aee`. Its
`/etc/fstab` entry is:

```text
UUID=b8566ede-b661-4074-8b5a-f2dc743d6aee /mnt/ssd ext4 defaults,nodev,nosuid,nofail,x-systemd.device-timeout=10s 0 2
```

The root-owned file `woodpecker-ci/.filesystem-uuid` contains that UUID and is mode
0444. Setup and teardown require the marker to match the configured UUID and
accept only a direct `pvc-<uuid>_woodpecker-ci_<claim>` directory, refusing
symlinks. If the disk is absent, helpers fail instead of using a directory on
the NVMe. Keep the CI class in the provisioner configuration while any of its
PVs exist, including ones awaiting deletion. Existing NVMe symlinks retain their
setup and teardown behavior.

On 2026-10-12 Morten approved repurposing this disk after confirming it was not
configured on the host. Its obsolete ZFS signatures (pool label `SSD`) were
erased from sda2 and that partition formatted. GPT and sda1 were preserved.
The previous fstab is `/etc/fstab.before-573f2ae1`. This data deletion cannot be
undone by a Git revert. Reboot persistence is configured; no reboot was performed.

## Verification and recovery

- Check `findmnt -T /mnt/ssd -o SOURCE,TARGET,FSTYPE,UUID` on the host.
- A running workflow's PVC must use `woodpecker-ci`; its PV's local path must be
  below `/mnt/ssd/woodpecker-ci`, and its mounted filesystem must be ext4
  on sda2. Confirm actual writes in `node_disk_written_bytes_total{device="sda"}`.
- Test concurrent real installs while observing both disks, node I/O pressure,
  control-plane responsiveness and service restarts before increasing concurrency.
- On a missing disk, stop CI admission and repair the mount. Never create the
  marker in the underlying NVMe directory. An idle agent can be returned to
  `local-path` at two workflows through an apps PR. Leave this class/config and
  the host mount in place until all CI PVs have drained; do not erase volumes
  to make a rollback finish.

Workspace isolation does not move container writable layers, image unpacking,
runtime logs or caches outside the workspace. Local-path does not enforce PVC
capacity: `10G` is a claim size, not a quota. Monitor filesystem free space.

Source details: [versioned local-path configuration](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/README.md#configuration),
[helper implementation](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/provisioner.go),
[Woodpecker workflow PVCs](https://github.com/woodpecker-ci/woodpecker/blob/v3.19.0/pipeline/backend/kubernetes/volume.go).

## Checks

`mise install && scripts/ci/validate-charts.sh` runs the same checks locally and
in `.woodpecker/charts.yaml` on PRs, pushes and manual runs. It lints the shared
and monitor charts, renders class wiring and exercises the rendered storage
scripts in temporary directories, then tests alert firing and recovery with
promtool 3.15.0. Tool versions and the Prometheus archive checksum are pinned.
Set `PROMTOOL` to an existing executable to avoid downloading it locally.
