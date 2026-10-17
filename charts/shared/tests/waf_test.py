"""Check the rendered gateway traffic boundary, not template text."""
import json
from pathlib import Path
import subprocess


def render(*settings):
    chart = Path(__file__).resolve().parents[1]
    output = subprocess.check_output([
        "helm", "template", "shared", str(chart), "--namespace", "shared", *settings
    ], text=True)
    documents = subprocess.check_output(
        ["yq", "-o=json", "-I=0", "."], input=output, text=True
    )
    return [obj for line in documents.splitlines()
            if (obj := json.loads(line)) and obj["kind"] == "WasmPlugin"]


plugin, = render("--set", "resources.waf.enabled=true")
assert plugin["metadata"]["namespace"] == "istio-ingress"
spec = plugin["spec"]
assert spec["selector"]["matchLabels"] == {"istio": "gateway"}
assert spec["match"] == [{
    "mode": "CLIENT", "ports": [{"number": 18080}, {"number": 18443}]
}], "Gateway listeners must match CLIENT traffic, restricted to public ports"
assert spec["failStrategy"] == "FAIL_OPEN"
assert spec["url"] == "oci://ghcr.io/corazawaf/coraza-proxy-wasm:0.6.0"
assert spec["pluginConfig"]["directives_map"]["default"] == [
    "Include @demo-conf", "Include @crs-setup-conf",
    "Include @owasp_crs/*.conf", "SecRuleEngine DetectionOnly"
]
assert not spec["pluginConfig"].get("per_authority_directives"), "No host bypasses"
print("ok: CRS detection covers only public gateway listeners and remains fail-open")

assert render("--set", "resources.waf.enabled=false") == []
plugin, = render("--set", "resources.waf.enabled=true",
                 "--set", "resources.gateways.public.httpPort=28080",
                 "--set", "resources.gateways.public.httpsPort=28443")
assert plugin["spec"]["match"] == [{
    "mode": "CLIENT", "ports": [{"number": 28080}, {"number": 28443}]
}], "Port overrides must follow the public Gateway rather than fixed defaults"
print("ok: WAF can be disabled and follows public port overrides")
