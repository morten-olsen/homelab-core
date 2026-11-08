"""Guard the approved Falco exception boundary in the rendered Application.

CI step pods run arbitrary code by design, so every loaded rule ignores the
woodpecker-ci namespace and nothing else (HOMEIT-496). This checks the rendered
rules, not syscall replay; use falco -V against the live falco_rules.yaml for
native rule compilation and observe a real pipeline after rollout.
"""
import json
from pathlib import Path
import subprocess

chart = Path(__file__).resolve().parents[1]

# The stable falco_rules.yaml rules loaded on the node (falco 0.45, 2026-10-30)
# plus the locally redefined API-server rule.
COVERED = {
    "Clear Log Activities",
    "Contact K8S API Server From Container",
    "Create Hardlink Over Sensitive Files",
    "Create Symlink Over Sensitive Files",
    "Debugfs Launched in Privileged Container",
    "Detect release_agent File Container Escapes",
    "Directory traversal monitored file read",
    "Disallowed SSH Connection Non Standard Port",
    "Drop and execute new binary in container",
    "Execution from /dev/shm",
    "Fileless execution via memfd_create",
    "Find AWS Credentials",
    "Linux Kernel Module Injection Detected",
    "Netcat Remote Code Execution in Container",
    "PTRACE anti-debug attempt",
    "PTRACE attached to process",
    "Packet socket created in container",
    "Read sensitive file trusted after startup",
    "Read sensitive file untrusted",
    "Redirect STDOUT/STDIN to Network Connection in Container",
    "Remove Bulk Data from Disk",
    "Run shell untrusted",
    "Search Private Keys or Passwords",
    "System user interactive",
    "Terminal shell in container",
}
CI = {"name": "ci_workloads", "fields": ["k8s.ns.name"], "comps": ["="], "values": [["woodpecker-ci"]]}
# Approved workload exceptions, separate from the namespace-wide CI exclusion.
OTHER = {
    "Run shell untrusted": {"cnpg_wal_archiver"},
    "Drop and execute new binary in container": {
        "known_images", "forgejo_image_binary", "flaresolverr_patched_chromedriver",
    },
}


def yaml_documents(text):
    output = subprocess.check_output(
        ["yq", "-o=json", "-I=0", "."], input=text, text=True
    )
    return [json.loads(line) for line in output.splitlines()]


rendered = subprocess.check_output(
    ["helm", "template", "core", str(chart)], text=True
)
app, = [o for o in yaml_documents(rendered) if o and o.get("metadata", {}).get("name") == "falco"]
values, = yaml_documents(app["spec"]["source"]["helm"]["values"])
rules = yaml_documents(values["customRules"]["custom-rules.yaml"])[0]
by_name = {}
for rule in rules:
    if "rule" in rule:
        assert rule["rule"] not in by_name, f"One entry per rule: {rule['rule']}"
        by_name[rule["rule"]] = rule

assert set(by_name) == COVERED, set(by_name) ^ COVERED
for name, rule in by_name.items():
    if name != "Contact K8S API Server From Container":
        assert rule.get("override") == {"exceptions": "append"}, name
        assert set(rule) == {"rule", "override", "exceptions"}, f"{name} only adds exceptions"
    exceptions = {e["name"]: e for e in rule["exceptions"]}
    assert exceptions.pop("ci_workloads") == CI, f"{name} must ignore exactly woodpecker-ci"
    assert set(exceptions) == OTHER.get(name, set()), name

# Every field is an equality in a single tuple: no image-wide, namespace-wide,
# alternate-executable, parent or UID escape from the drop-and-execute rule.
drop_exceptions = {
    e["name"]: e for e in by_name["Drop and execute new binary in container"]["exceptions"]
}
assert drop_exceptions["flaresolverr_patched_chromedriver"] == {
    "name": "flaresolverr_patched_chromedriver",
    "fields": [
        "k8s.ns.name", "container.name", "container.image.repository",
        "container.image.tag", "proc.exepath", "proc.name", "proc.pname",
        "proc.aname[2]", "user.uid",
    ],
    "comps": ["="] * 9,
    "values": [[
        "prod-containarr", "flaresolverr", "ghcr.io/flaresolverr/flaresolverr",
        "cd2872fa4a3e0bb10acee4063771adeba71feb8bf75311dd481a7a1ce3c32d36",
        "/app/chromedriver", "chromedriver", "python", "dumb-init", 1000,
    ]],
}, "FlareSolverr exclusion must stay limited to the approved image and execution identity"

text = json.dumps(rules)
for retired in ("kaniko", "/mise/installs/", '"prod"'):
    assert retired not in text, f"CI-specific exception left behind: {retired}"
print(f"ok: {len(COVERED)} CI rule scopes and pinned FlareSolverr execution boundary")
