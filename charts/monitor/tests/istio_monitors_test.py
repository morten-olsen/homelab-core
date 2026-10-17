"""Validate discovery and sample filtering for the gateway's agent endpoint."""
import json
from pathlib import Path
import re
import subprocess

chart = Path(__file__).resolve().parents[1]
output = subprocess.check_output([
    "helm", "template", "monitor", str(chart), "--namespace", "monitoring",
    "--show-only", "templates/istio-monitors.yaml"
], text=True)
documents = subprocess.check_output(
    ["yq", "-o=json", "-I=0", "."], input=output, text=True
)
objects = [json.loads(line) for line in documents.splitlines()]
monitor, = [obj for obj in objects if obj["kind"] == "PodMonitor"]
assert monitor["metadata"]["namespace"] == "monitoring"
spec = monitor["spec"]
assert spec["namespaceSelector"] == {"matchNames": ["istio-ingress"]}
assert spec["selector"] == {"matchLabels": {"app": "gateway"}}
assert len(spec["podMetricsEndpoints"]) == 1, "Scrape merged metrics once; avoid the sidecar-intercepted 15090 endpoint"
agent, = spec["podMetricsEndpoints"]
assert agent["port"] == "http-envoy-prom", "Discover one declared port per gateway"
assert agent["path"] == "/stats/prometheus" and agent["interval"] == "15s"
rewrite, = agent["relabelings"]
assert rewrite["sourceLabels"] == ["__address__"]
assert rewrite["targetLabel"] == "__address__"
assert rewrite["replacement"] == "${1}:15020"
match = re.fullmatch(rewrite["regex"], "10.42.0.93:15090")
assert match and match.group(1) == "10.42.0.93", "Use the pod IP, not a Service or admin port"
assert not agent.get("metricRelabelings"), "Retain gateway Envoy, waf_filter_* and agent health together"
assert {obj["kind"] for obj in objects} == {"PodMonitor", "ServiceMonitor"}
print("ok: a single merged gateway scrape avoids sidecar interception and retains WAF transactions")
