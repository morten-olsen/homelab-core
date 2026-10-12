import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
objects = json.loads((root / "objects.json").read_text())
classes = {obj["metadata"]["name"]: obj for obj in objects if obj["kind"] == "StorageClass"}
assert "woodpecker-ci" in classes, "CI needs a dedicated storage class"
ci = classes["woodpecker-ci"]
assert ci["provisioner"] == "rancher.io/local-path"
assert ci["volumeBindingMode"] == "WaitForFirstConsumer"
assert ci["reclaimPolicy"] == "Delete"
assert ci["metadata"]["annotations"]["defaultVolumeType"] == "local", "Match the node-local PV convention of the default class"
assert "storageclass.kubernetes.io/is-default-class" not in ci["metadata"].get("annotations", {})
config = next(obj["data"] for obj in objects if obj["kind"] == "ConfigMap")
paths = json.loads(config["config.json"])
assert paths["nodePathMap"] == []
assert paths["storageClassConfigs"]["local-path"]["nodePathMap"][0]["paths"] == [str(root / "nvme")]
assert paths["storageClassConfigs"]["woodpecker-ci"]["nodePathMap"] == [{"node": "compute", "paths": [str(root / "ci")]}]
print("ok: CI and default class provision on separate roots")

def run(script, volume, success=True):
    result = subprocess.run(["sh", "-s"], input=config[script], text=True,
                            env={**os.environ, "VOL_DIR": str(volume)}, capture_output=True)
    assert (result.returncode == 0) == success, (script, volume, result.stdout, result.stderr)

ci_root = root / "ci"
ci_root.mkdir()
(ci_root / ".filesystem-uuid").write_text("test-filesystem\n")
volume = ci_root / "pvc-01234567-1234-1234-1234-0123456789ab_woodpecker-ci_workspace"
run("setup", volume)
assert volume.is_dir() and not volume.is_symlink(), "CI data must stay on the CI filesystem"
(volume / "payload").write_text("workspace")
run("teardown", volume)
assert not volume.exists()
assert (ci_root / ".filesystem-uuid").exists()
print("ok: rendered CI scripts create and remove only the workspace directory")

# An unmounted disk exposes an empty host directory, never a valid marker.
(ci_root / ".filesystem-uuid").unlink()
run("setup", volume, success=False)
assert not volume.exists()
volume.mkdir()
(volume / "payload").write_text("keep while disk is missing")
run("teardown", volume, success=False)
assert (volume / "payload").exists()
(volume / "payload").unlink()
volume.rmdir()
(ci_root / ".filesystem-uuid").write_text("wrong-disk\n")
run("setup", volume, success=False)
(ci_root / ".filesystem-uuid").write_text("test-filesystem\n")
outside = root / "protected"
outside.mkdir()
(outside / "data").write_text("keep")
volume.symlink_to(outside, target_is_directory=True)
run("setup", volume, success=False)
run("teardown", volume, success=False)
assert (outside / "data").read_text() == "keep"
volume.unlink()
for path in [ci_root, ci_root / "../protected", ci_root / "pvc-bad/nested", outside]:
    run("setup", path, success=False)
    run("teardown", path, success=False)
assert (outside / "data").exists()
print("ok: absent or incorrect disk markers, symlinks and paths outside a CI workspace are refused")

nvme = root / "nvme"
nvme.mkdir()
legacy = nvme / "pvc-01234567-1234-1234-1234-0123456789ab_prod_example-data"
pretty = nvme / "pvc/prod/example-data"
run("setup", legacy)
assert legacy.is_symlink() and legacy.resolve() == pretty
(pretty / "payload").write_text("legacy")
run("teardown", legacy)
assert not legacy.is_symlink() and not pretty.exists()
legacy.mkdir()
run("teardown", legacy)
assert not legacy.exists()
print("ok: NVMe symlink provisioning and historical direct-directory cleanup still work")

# A helper must never treat a nested path or a crafted symlink as an app PVC.
for path in [nvme / "pvc-bad/nested", nvme / "pvc-crafted"]:
    path.parent.mkdir(exist_ok=True)
    path.symlink_to(nvme / "pvc/../protected", target_is_directory=True)
    run("teardown", path, success=False)
    path.unlink()
print("ok: unexpected NVMe paths and crafted symlink targets are refused")
