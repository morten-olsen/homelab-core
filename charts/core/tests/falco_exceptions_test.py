"""Guard the approved Falco exception boundary in the rendered Application.

This checks equality tuples, not syscall replay; use Falco --validate for native
rule compilation and observe a real build after rollout.
"""
import json
from pathlib import Path
import subprocess

chart = Path(__file__).resolve().parents[1]


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
by_name = {r["rule"]: r for r in rules if "rule" in r}
identity = {
    "k8s.ns.name": "woodpecker-ci",
    "container.image.repository": "code.olsen.cloud/ci/kaniko-build",
    "proc.name": "executor",
    "proc.pname": "containerd-shim",
    "proc.exepath": "/kaniko/executor",
}
approved = {
    "Read sensitive file untrusted": {
        "/etc/shadow", "/etc/pam.conf",
        *["/etc/pam.d/" + name for name in (
            "runuser-l", "common-session-noninteractive", "newusers", "runuser",
            "common-account", "chfn", "su", "su-l", "common-auth", "login",
            "other", "common-session", "passwd", "chpasswd", "chsh", "common-password",
        )],
    },
    "Clear Log Activities": {
        "/var/log/alternatives.log", "/var/log/dpkg.log", "/var/log/btmp",
        "/var/log/faillog", "/var/log/lastlog", "/var/log/wtmp",
    },
}
positive = negative = 0
for name, paths in approved.items():
    assert name in by_name, f"Missing approved override: {name}"
    rule = by_name[name]
    assert rule["override"] == {"exceptions": "append"}
    exception, = rule["exceptions"]
    fields = [*identity, "fd.name"]
    assert exception["fields"] == fields
    assert exception["comps"] == ["="] * len(fields), "No prefix, glob or list comparisons"
    tuples = exception["values"]
    assert len(tuples) == len(paths)
    assert {tuple(row) for row in tuples} == {
        (*identity.values(), path) for path in paths
    }, "Only the approved identities and exact files may be excluded"

    def excluded(event):
        return any(all(event.get(field) == value for field, value in zip(fields, row))
                   for row in tuples)

    for path in paths:
        event = identity | {"fd.name": path}
        assert excluded(event)
        positive += 1
        for field in fields:
            assert not excluded(event | {field: "different"})
            assert not excluded({k: v for k, v in event.items() if k != field})
            negative += 2
        assert not excluded(event | {"k8s.ns.name": "prod"})
        assert not excluded(event | {"fd.name": path + "/child"})
        negative += 2
    assert not excluded(identity | {"fd.name": "/var/log/fontconfig.log"})
    assert not excluded(identity | {"fd.name": "/etc/shadow.backup"})
    assert not excluded(identity | {"proc.name": "fontconfig.post", "proc.pname": "dpkg",
                                    "proc.exepath": "/usr/bin/dash", "fd.name": "/var/log/fontconfig.log"})
    negative += 3

# No Kaniko scope may be added to the dominant execution rule.
new_binary = by_name["Drop and execute new binary in container"]
assert "kaniko" not in json.dumps(new_binary)
print(f"ok: {positive} approved exact tuples excluded; {negative} boundary cases retained; new-binary unchanged for Kaniko")
