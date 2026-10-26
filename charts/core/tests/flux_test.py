"""Render the maintained Flux chart to guard the existing installation boundary."""
import json
from pathlib import Path
import subprocess

chart = Path(__file__).resolve().parents[1]


def documents(text):
    output = subprocess.check_output(
        ["yq", "-o=json", "-I=0", "."], input=text, text=True
    )
    return [obj for line in output.splitlines() if (obj := json.loads(line))]


applications = documents(subprocess.check_output(
    ["helm", "template", "core", str(chart)], text=True
))
app, = [obj for obj in applications if obj["metadata"]["name"] == "flux"]
assert app["spec"]["destination"]["namespace"] == "flux-system"
source = app["spec"]["source"]
# Exercise the actual chart, not just the values passed to it. Helm caches the
# repository normally; CI therefore needs access to the public Helm repository.
rendered = subprocess.check_output([
    "helm", "template", "flux", source["chart"],
    "--repo", source["repoURL"], "--version", source["targetRevision"],
    "--namespace", "flux-system", "--values", "-",
], input=source["helm"]["values"], text=True)
objects = documents(rendered)
deployments = {obj["metadata"]["name"]: obj for obj in objects if obj["kind"] == "Deployment"}
assert set(deployments) == {"helm-controller", "source-controller"}, "Do not enable additional controllers"
for name, deployment in deployments.items():
    spec = deployment["spec"]
    assert spec["selector"] == {"matchLabels": {"app": name}}, "Live selectors are immutable"

service, = [obj for obj in objects if obj["kind"] == "Service"]
assert service["metadata"]["name"] == "source-controller"
assert service["spec"]["selector"] == {"app": "source-controller"}
assert service["spec"]["ports"] == [{"name": "http", "port": 80, "protocol": "TCP", "targetPort": "http"}]
assert deployments["source-controller"]["spec"]["strategy"] == {"type": "Recreate"}
crds = [obj for obj in objects if obj["kind"] == "CustomResourceDefinition"]
assert {obj["metadata"]["name"] for obj in crds} == {
    "helmreleases.helm.toolkit.fluxcd.io", "buckets.source.toolkit.fluxcd.io",
    "gitrepositories.source.toolkit.fluxcd.io", "helmrepositories.source.toolkit.fluxcd.io",
    "helmcharts.source.toolkit.fluxcd.io", "ocirepositories.source.toolkit.fluxcd.io",
}
for crd in crds:
    annotations = crd["metadata"]["annotations"]
    assert set(annotations["argocd.argoproj.io/sync-options"].split(",")) >= {"Prune=false", "Delete=false"}

role, = [obj for obj in objects if obj["kind"] == "ClusterRole"
         and obj["metadata"]["name"] == "flux-controller-runtime-flux-system"]
assert role["rules"] == [
    {"apiGroups": [""], "resources": ["serviceaccounts/token"], "verbs": ["create"]},
    {"nonResourceURLs": ["/livez/ping"], "verbs": ["head"]},
]
binding, = [obj for obj in objects if obj["kind"] == "ClusterRoleBinding"
            and obj["metadata"]["name"] == role["metadata"]["name"]]
assert {subject["name"] for subject in binding["subjects"]} == set(deployments)
assert all(subject["namespace"] == "flux-system" for subject in binding["subjects"])

umbrella = chart.parent / "homelab"
for enabled in ("true", "false"):
    applications = documents(subprocess.check_output([
        "helm", "template", "homelab", str(umbrella), "--set", f"features.gitops={enabled}"
    ], text=True))
    operators, = [obj for obj in applications if obj["kind"] == "Application"
                  and obj["metadata"]["name"] == "core"]
    values, = documents(operators["spec"]["source"]["helm"]["values"])
    assert values["operators"]["flux"]["enabled"] == (enabled == "true")
print("ok: Flux adoption preserves selectors, controller boundaries, source service, CRDs and runtime RBAC")
