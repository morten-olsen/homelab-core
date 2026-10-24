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

`charts/monitor/templates/istio-monitors.yaml` uses one merged scrape of the
gateway's pod IP on 15020 `/stats/prometheus`. The existing `istio-gateway`
PodMonitor retains its `app=gateway` selector and `istio-ingress` scope. No
Service, public route, admin endpoint, RBAC grant or gateway pod change is added.

The gateway declares only `http-envoy-prom` (15090). The PodMonitor discovers
that single port and relabels `__address__` to 15020. `portNumber: 15020` would
drop the target because that port is undeclared. This address is reachable from
Prometheus's config-reloader container with its BusyBox HTTP client.

Runtime verification found a trap: Prometheus has a native Istio sidecar, which
captures outbound traffic to 15090 and serves its own statistics. The old
15090 target was `up=1`, but its Istio series identified the Prometheus workload,
not the gateway. From the same container, gateway-IP:15020/stats/prometheus
returns the real gateway's `waf_filter_tx_total` and agent WASM health. Using the
merged endpoint once retains gateway Envoy, Coraza and agent statistics without
double scraping. Verify the source workload/transaction counter as well as `up`.

Use `up{job="monitoring/istio-gateway",instance=~".*:15020"}` for scrape health.
Module metrics include (fetch/conversion series may be absent before an attempt):

- `istio_agent_wasm_cache_entries`
- `istio_agent_wasm_remote_fetch_count`, grouped by `result`
- `istio_agent_wasm_config_conversion_count`, grouped by `result`

Coraza 0.6.0 exposes `waf_filter_tx_total`, an unlabeled transaction counter,
not the ticket's assumed `wasmcustom_coraza_*` family. It does not attach the
configured owner/identifier labels to that total. Use the PodMonitor's pod/job
labels. Discover other series from runtime before adding dashboard queries;
rule logs are not interchangeable with interruption metrics in DetectionOnly.
The [0.6.0 metrics implementation](https://github.com/corazawaf/coraza-proxy-wasm/blob/0.6.0/wasmplugin/metrics.go)
provides transaction and actual-interruption counters, not an anomaly histogram
or per-rule detection counter. Review sanitized rule-log counts for false
positives; do not present absent interruption series as a would-block count.

Scrape health and successful fetching do not prove request inspection. Follow
the [WAF runtime checks](networking.md#controlled-inspection-check), compare
per-port transaction and sanitized rule-log deltas, then confirm retention in
Prometheus. Keep rule counts aggregate; never put request/audit content in
metric labels or panels. Retention is 30 days or 50GiB, whichever removes data
first. Burn-in starts only after public-positive/private-negative inspection
and retained telemetry are verified; the initial deployment's elapsed time is
not evidence of this.

### Gateway duplicate message timestamps

HOMEIT-431 traced `PrometheusDuplicateTimestamps` to four conflicting samples
per gateway scrape: `istio_request_messages_total` and
`istio_response_messages_total`, each for NetBird management and signal. Each
pair had identical labels and different counter values in both the merged
15020 endpoint and Envoy's direct 15090 endpoint. A single healthy target did
not prove that every sample was retained. Changing scrape ports or timestamps
would not repair this exporter output.

`templates/gateway-telemetry.yaml` adds `gateway_listener_port` to only those
two metric families through the [Istio Telemetry API](https://istio.io/latest/docs/reference/config/telemetry/),
using `string(destination.port)`. The Telemetry resource
selects `app=gateway` in `istio-ingress`; it does not change mesh-wide metrics.
The label is the downstream local listener port, bounded by configured
listeners (currently private 80/443 and public 18080/18443), rather than a
request path, client address or connection ID. Existing queries that sum across
listeners still work. No samples or alerts are disabled.

A temporary live diagnostic confirmed xDS applied the two overrides, and
nonexistent gRPC methods returned `UNIMPLEMENTED` through private TLS 443 and
public TLS 18443. Newly generated message counters were retained as distinct
listener-labeled identities. Old listener/stream scopes continued to expose
unlabeled conflicting counters; this diagnostic alone did not clear the alert
or prove an upstream allocator fix. Remove temporary diagnostic resources when
finished, and make the retained configuration through GitOps.

After reconciliation, inspect the live Telemetry and gateway `istio.stats`
configuration, then check the entire raw merged payload for duplicate
name/label identities. Old counters can survive an xDS update; if they remain,
perform a controlled rolling gateway restart to retire those scopes, recording
the recovery action in the task. Verify gateway availability and NetBird
endpoints through the rollover. Confirm both gRPC families have retained
samples on both TLS listeners, and retain the Envoy, `waf_filter_tx_total` and
agent health metrics from the same scrape. Finally require no increase in
`prometheus_target_scrapes_sample_duplicate_timestamp_total` over the full
five-minute rule lookback, no new ingest warnings, and no active
`PrometheusDuplicateTimestamps`
in Prometheus or Alertmanager. Run the base repository's `task health:check`.
