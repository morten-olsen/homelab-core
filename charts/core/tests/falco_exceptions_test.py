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
# Workload exceptions that predate the CI exclusion and stay as they are.
OTHER = {
    "Run shell untrusted": {"cnpg_wal_archiver"},
    "Drop and execute new binary in container": {"known_images", "forgejo_image_binary"},
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

text = json.dumps(rules)
for retired in ("kaniko", "/mise/installs/", '"prod"'):
    assert retired not in text, f"CI-specific exception left behind: {retired}"
print(f"ok: {len(COVERED)} rules ignore woodpecker-ci only; other workload exceptions unchanged")
