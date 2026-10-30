"""Render Grafana with grafanaSso through the real kube-prometheus-stack chart."""
import configparser
import json
from pathlib import Path
import subprocess

chart = Path(__file__).resolve().parents[1]
sso = ["--set", "grafanaSso.enabled=true", "--set", "global.domain=example.org"]


def documents(text):
    output = subprocess.check_output(
        ["yq", "-o=json", "-I=0", "."], input=text, text=True
    )
    return [obj for line in output.splitlines() if (obj := json.loads(line))]


def render(*args):
    return documents(subprocess.check_output(
        ["helm", "template", "monitor", str(chart), "--namespace", "monitoring", *args],
        text=True,
    ))


assert not [o for o in render() if o["kind"] == "AuthentikClient"]

objects = render(*sso)
client, = [o for o in objects if o["kind"] == "AuthentikClient"]
assert client["metadata"] == {"name": "grafana", "namespace": "monitoring"}
spec = client["spec"]
assert spec["allowedGroups"] == [{"name": "admin", "namespace": "shared"}]
assert spec["clientId"] == "grafana" and spec["secretName"] == "grafana-oidc-credentials"
assert spec["redirectUris"] == ["https://grafana.example.org/login/generic_oauth"]

app, = [o for o in objects if o["kind"] == "Application" and o["metadata"]["name"] == "prometheus-operator"]
source = app["spec"]["source"]
rendered = documents(subprocess.check_output([
    "helm", "template", "prometheus-operator", source["chart"],
    "--repo", source["repoURL"], "--version", source["targetRevision"],
    "--namespace", "monitoring", "--values", "-",
], input=source["helm"]["values"], text=True))
config, = [o for o in rendered if o["kind"] == "ConfigMap" and o["metadata"]["name"] == "prometheus-operator-grafana"]
ini = configparser.ConfigParser(interpolation=None)
ini.read_string(config["data"]["grafana.ini"])
oauth = ini["auth.generic_oauth"]
assert oauth["enabled"] == "true" and oauth["client_id"] == "grafana"
assert oauth["auth_url"] == "https://auth.example.org/application/o/authorize/"
assert oauth["role_attribute_path"] == "contains(groups[*], 'gitops/shared/admin') && 'Admin'"
assert oauth["role_attribute_strict"] == "true", "Users without the admin group get no role"
assert ini["auth"]["disable_login_form"] == "false", "The local admin stays as breakglass"
assert ini["server"]["root_url"] == "https://grafana.example.org/"

deployment, = [o for o in rendered if o["kind"] == "Deployment" and o["metadata"]["name"] == "prometheus-operator-grafana"]
grafana, = [c for c in deployment["spec"]["template"]["spec"]["containers"] if c["name"] == "grafana"]
env = {e["name"]: e for e in grafana["env"]}
assert env["GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"]["valueFrom"] == {
    "secretKeyRef": {"name": "grafana-oidc-credentials", "key": "clientSecret"}
}
assert env["GF_SECURITY_ADMIN_USER"]["valueFrom"]["secretKeyRef"]["name"] == "grafana-admin"
print("ok: grafana SSO admits only the admin group and keeps the local admin")
