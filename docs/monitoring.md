# Monitoring

The monitoring stack runs in the `monitoring` namespace and is managed by the `charts/monitor` Helm chart, deployed via ArgoCD.

## Stack

| Component | Purpose |
|---|---|
| **Prometheus** (kube-prometheus-stack) | Metrics collection, rule evaluation |
| **Alertmanager** | Alert routing and deduplication |
| **Grafana** | Dashboards (private, at `grafana.olsen.cloud`) |
| **Blackbox Exporter** | HTTP health probes for internal services |
| **node-exporter hwmon** | Host CPU, NVMe, DIMM, board, and thermal-zone temperature metrics |

## Alert routing

All alerts flow through Alertmanager, which currently has no push receiver: every route ends at the `null` receiver, so alerts are visible only in Alertmanager and Grafana.

The former `ntfy-alertmanager` bridge was removed because it could not deliver (ntfy rejected it with 403) and its failures fed `AlertmanagerFailedToSendAlerts`. Push delivery is to be redesigned separately.

## Custom alert rules

Defined in `charts/monitor/templates/prometheus-rules.yaml`. These replace or supplement noisy defaults with homelab-appropriate thresholds and patience windows.

### Node
- **NodeIOPressure** — full I/O stalls >10% over 1m, sustained 30s → warning.
  Inspect NVMe and CI disk writes and reduce CI concurrency if services stall.
- **NodeDiskWarning** — root or CI FS <15% free for 5m → warning
- **NodeDiskCritical** — root or CI FS <5% free for 5m → critical
- **NodeMemoryPressure** — memory >90% for 15m → warning
- **NodeHighLoad** — load15 >6 for 15m → warning

### Pods
- **PodCrashLooping** — >3 restarts in 15m, sustained 15m → critical
- **PodStuckNotReady** — running but not ready for 30m → warning

### Storage
- **PVCAlmostFull** — PVC <15% free for 5m → warning
- **PVCFull** — PVC <3% free for 5m → critical

### HTTP probes
- **ServiceDown** — HTTP probe failing for 3m → critical
- **ServiceSlowResponse** — probe >5s for 10m → warning

## Disabled default rules

Several kube-prometheus-stack defaults are disabled as they don't apply to a single-node k3s cluster or produce constant noise:

| Disabled | Reason |
|---|---|
| `kubeProxy` rule group | k3s has no kube-proxy pod |
| `kubeSchedulerAlerting/Recording` groups | k3s embeds the scheduler |
| `KubeControllerManagerDown` | k3s embeds the controller manager |
| `KubeSchedulerDown` | k3s embeds the scheduler |
| `KubeProxyDown` | k3s has no kube-proxy pod |
| `CPUThrottlingHigh` | Fires constantly on JVM/interpreted workloads, not actionable |
| `KubePodNotReady` | Replaced by `PodStuckNotReady` with a 30m patience window |

## HTTP probing (Blackbox Exporter)

`charts/monitor/templates/blackbox-probes.yaml` defines two `Probe` CRDs that tell Prometheus to run HTTP checks via the Blackbox Exporter every 60 seconds against internal cluster services.

**Platform services** (`probe_group=platform`): argocd, grafana, alertmanager, pihole, ntfy

**Application services** (`probe_group=application`): jellyfin, jellyfin-kids, immich, home-assistant, vaultwarden, mealie, homebox, miniflux, n8n, forgejo, audiobookshelf, komga, readeck, vikunja

All probes target internal ClusterIP services (`*.svc.cluster.local`), not external URLs. This tests that the application is running, independent of Istio gateway health.

The `ServiceDown` and `ServiceSlowResponse` alert rules fire on `probe_success == 0` and `probe_duration_seconds > 5` respectively, routing through the same Alertmanager pipeline as infrastructure alerts.

## Configuration

To add a new HTTP probe target, add the internal service URL to the appropriate list in `charts/monitor/templates/blackbox-probes.yaml`.

To change alert thresholds or add new rules, edit `charts/monitor/templates/prometheus-rules.yaml`.

## Host thermal dashboard

`charts/monitor/templates/grafana-dashboard-host-thermals.yaml` defines the
**Homelab Host Thermals** dashboard from existing node-exporter metrics. It uses
`node_hwmon_temp_celsius`, `node_hwmon_temp_crit_celsius`,
`node_thermal_zone_temp`, and `node_boot_time_seconds` to trend CPU, NVMe, DIMM,
board/WMI, and ACPI thermal-zone readings alongside reboot markers.

The ACPI thermal zone includes the known bogus Gigabyte reading documented in the
stability investigation; use the dashboard for trend/correlation, not as proof
that the bogus ACPI critical threshold is real.

## Gateway WASM health

`charts/monitor/templates/istio-monitors.yaml` keeps the gateway Envoy scrape on
pod port 15090 at `/stats/prometheus`, and adds an agent scrape on the same pod
IP at 15020 `/metrics`. Both use the existing `istio-gateway` PodMonitor,
`app=gateway` selector and `istio-ingress` namespace scope. No Service,
VirtualService, public route, admin endpoint or RBAC grant is added.

The gateway declares only the named `http-envoy-prom` container port (15090).
The second endpoint discovers that single port and relabels `__address__` to
15020. Using `portNumber: 15020` directly would drop the target because that
port is undeclared. Before implementation, `/metrics` was reachable on the pod
IP from Prometheus's config-reloader container using its BusyBox HTTP client.
Verify the generated target is healthy after deployment; no restart is required.

The agent endpoint merges Envoy statistics. A metric allowlist retains only
`istio_agent_wasm_*` there to avoid ingesting the same Envoy/Coraza series twice.
Use `up{job="monitoring/istio-gateway",instance=~".*:15020"}` for scrape health
and the following module metrics (fetch/conversion series may be absent before
any attempt):

- `istio_agent_wasm_cache_entries`
- `istio_agent_wasm_remote_fetch_count`, grouped by `result`
- `istio_agent_wasm_config_conversion_count`, grouped by `result`

Scrape health and successful fetching do not prove request inspection. Follow
the [WAF runtime checks](networking.md#controlled-inspection-check), discover
actual Coraza counters on the 15090 scrape, and confirm them in Prometheus
before creating dashboard queries. Keep rule counts aggregate; do not put
request or audit content in metric labels or dashboard panels. Retention is
30 days or 50GiB, whichever removes data first. Burn-in starts only after the
public-positive/private-negative check and retained telemetry are verified.
