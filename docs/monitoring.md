# Monitoring

The monitoring stack runs in the `monitoring` namespace and is managed by the `charts/monitor` Helm chart, deployed via ArgoCD.

## Stack

| Component | Purpose |
|---|---|
| **Prometheus** (kube-prometheus-stack) | Metrics collection, rule evaluation |
| **Alertmanager** | Alert routing and deduplication |
| **Grafana** | Dashboards (private, at `grafana.olsen.cloud`) |
| **Blackbox Exporter** | HTTP health probes for internal services |
| **ntfy-alertmanager** | Bridge: Alertmanager webhooks → ntfy notifications |
| **ntfy** | Push notification delivery (app layer, `ntfy.olsen.cloud`) |

## Alert routing

All alerts flow through Alertmanager and are delivered to ntfy (`homelab-alerts` topic) via the `ntfy-alertmanager` bridge running in the monitoring namespace.

| Severity | Repeat interval | Examples |
|---|---|---|
| **critical** | 1 hour | Node disk >95%, pod crash-looping, service down, PVC nearly full |
| **warning** | 4 hours | Node disk >85%, memory pressure, pod stuck not-ready |
| *(none/info)* | — | Silenced — not actionable for a single-person homelab |

The `Watchdog` alert (Prometheus canary) and `InfoInhibitor` are routed to null.

## Custom alert rules

Defined in `charts/monitor/templates/prometheus-rules.yaml`. These replace or supplement noisy defaults with homelab-appropriate thresholds and patience windows.

### Node
- **NodeDiskWarning** — root FS <15% free for 5m → warning
- **NodeDiskCritical** — root FS <5% free for 5m → critical
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

Key values in `charts/monitor/values.yaml`:

```yaml
ntfy:
  url: http://ntfy.prod.svc.cluster.local  # internal ntfy service
  topic: homelab-alerts                    # ntfy topic to publish to
```

To add a new HTTP probe target, add the internal service URL to the appropriate list in `charts/monitor/templates/blackbox-probes.yaml`.

To change alert thresholds or add new rules, edit `charts/monitor/templates/prometheus-rules.yaml`.
