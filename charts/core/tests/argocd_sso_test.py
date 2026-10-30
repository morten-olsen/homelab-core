"""Render ArgoCD with argocdSso through the real argo-cd chart."""
import json
from pathlib import Path
import subprocess

chart = Path(__file__).resolve().parents[1]


def documents(text):
    output = subprocess.check_output(
        ["yq", "-o=json", "-I=0", "."], input=text, text=True
    )
    return [obj for line in output.splitlines() if (obj := json.loads(line))]


def argocd_app(*args):
    apps = documents(subprocess.check_output(
        ["helm", "template", "core", str(chart), *args], text=True
    ))
    app, = [obj for obj in apps if obj["metadata"]["name"] == "argocd"]
    return app


# Disabled by default: the operator values pass through unchanged.
plain = argocd_app()
assert "oidc.config" not in plain["spec"]["source"]["helm"]["values"]

source = argocd_app(
    "--set", "argocdSso.enabled=true", "--set", "global.domain=example.org"
)["spec"]["source"]
rendered = subprocess.check_output([
    "helm", "template", "argocd", source["chart"],
    "--repo", source["repoURL"], "--version", source["targetRevision"],
    "--namespace", "argocd", "--values", "-",
], input=source["helm"]["values"], text=True)
configmaps = {
    obj["metadata"]["name"]: obj.get("data", {})
    for obj in documents(rendered) if obj["kind"] == "ConfigMap"
}
cm = configmaps["argocd-cm"]
assert cm["url"] == "https://argocd.example.org"
assert cm["admin.enabled"] == "true", "The local admin stays as breakglass"
oidc = documents(cm["oidc.config"])[0]
assert oidc == {
    "name": "Authentik",
    "issuer": "https://auth.example.org/application/o/argocd-argocd/",
    "clientID": "argocd",
    "enablePKCEAuthentication": True,
    "requestedScopes": ["openid", "profile", "email"],
}, oidc
rbac = configmaps["argocd-rbac-cm"]
assert rbac["policy.default"] == "", "Other SSO users get no role"
assert rbac["policy.csv"].strip() == "g, gitops/shared/admin, role:admin"
assert rbac["scopes"] == "[groups]"
# The rest of the operator values survive the merge.
params = configmaps["argocd-cmd-params-cm"]
assert params["server.insecure"] == "true"
print("ok: argocd SSO admits only the admin group and keeps the local admin")
