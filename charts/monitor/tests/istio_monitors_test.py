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
envoy, agent = spec["podMetricsEndpoints"]
assert envoy == {
    "port": "http-envoy-prom", "interval": "15s", "path": "/stats/prometheus"
}, "Keep the existing Envoy scrape"
assert agent["port"] == "http-envoy-prom", "Discover one declared port per gateway"
assert agent["path"] == "/metrics" and agent["interval"] == "15s"
rewrite, = agent["relabelings"]
assert rewrite["sourceLabels"] == ["__address__"]
assert rewrite["targetLabel"] == "__address__"
assert rewrite["replacement"] == "${1}:15020"
match = re.fullmatch(rewrite["regex"], "10.42.0.93:15090")
assert match and match.group(1) == "10.42.0.93", "Use the pod IP, not a Service or admin port"
allow, = agent["metricRelabelings"]
assert allow["action"] == "keep" and allow["sourceLabels"] == ["__name__"]
for name in ["istio_agent_wasm_cache_entries", "istio_agent_wasm_remote_fetch_count",
             "istio_agent_wasm_config_conversion_count"]:
    assert re.fullmatch(allow["regex"], name), f"Retain {name}"
for name in ["istio_requests_total", "envoy_server_memory_allocated",
             "wasmcustom_coraza_transactions_total", "process_resident_memory_bytes"]:
    assert not re.fullmatch(allow["regex"], name), f"Do not duplicate {name}"
assert {obj["kind"] for obj in objects} == {"PodMonitor", "ServiceMonitor"}
print("ok: existing gateway discovery scrapes WASM health without merged metric duplication")
