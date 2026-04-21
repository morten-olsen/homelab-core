# Homelab Platform Architecture

## Chart Hierarchy

The repo contains five Helm charts under `charts/`:

```
charts/
  homelab/      Umbrella chart -- feature flags, platform config, creates ArgoCD Applications
  core/         Operators      -- CRD controllers and cluster-wide tooling
  shared/       Platform       -- networking, TLS, databases, DNS, auth, backups
  monitor/      Observability  -- Prometheus stack, Grafana, alerting, probes
  demo/         Demo apps      -- sample applications for testing
```

The `homelab` chart is the entry point. It does not deploy any workloads itself.
Its templates translate **feature flags** into ArgoCD Applications for each sub-chart,
controlling what gets installed and passing platform configuration (domain, IP,
backup paths, etc.) through to each sub-chart.

```
ArgoCD
  |
  +-- homelab (Application)
        |
        +-- core   (Application, wave 0)
        |     +-- cert-manager    (Application)
        |     +-- external-secrets (Application)
        |     +-- istio-base      (Application)
        |     +-- ...one per operator
        |
        +-- shared (Application, wave 1)
        |     +-- gateway, cert-issuer, postgres-cluster, ...
        |     (resources rendered directly as Helm templates)
        |
        +-- monitor (Application, wave 2)  [conditional on features.monitoring]
              +-- prometheus-operator (Application)
              +-- blackbox-exporter   (Application)
              +-- PrometheusRule, Probe, ConfigMap dashboards, ...
              (mix of ArgoCD Applications and direct templates)
```

---

## Umbrella Chart (homelab)

The umbrella chart's `values.yaml` is the user-facing configuration interface.
It has three sections:

### Platform Identity

```yaml
platform:
  domain: example.com
  ip: 10.0.0.1
  timezone: UTC
  acme: prod
```

These values are passed to all sub-charts that need them (shared, monitor).

### Feature Flags

```yaml
features:
  serviceMesh: true
  certificates: true
  auth: true
  postgres: true
  monitoring: true
  # ... 16 flags total
```

Each flag maps to one or more operators (in the core chart) and platform resources
(in the shared chart). The mapping is defined in `templates/_helpers.tpl`:

- `homelab.operatorValues` -- maps features to `operators.X.enabled` flags
- `homelab.platformValues` -- maps features to `resources.X.enabled` flags + platform config
- `homelab.monitoringValues` -- passes domain, IP, ntfy config, backup paths

### Overrides (Escape Hatch)

```yaml
overrides:
  operators: {}   # deep-merged into core chart values
  platform: {}    # deep-merged into shared chart values
  monitoring: {}  # deep-merged into monitor chart values
```

Values in `overrides` are merged on top of the feature-derived values using
`mergeOverwrite`, giving power users full control without modifying sub-charts.

---

## Sync Wave Pattern

Each child Application carries an `argocd.argoproj.io/sync-wave` annotation that
controls deployment order:

| Wave | Chart   | Purpose |
|------|---------|---------|
| 0    | core    | Install operators and their CRDs |
| 1    | shared  | Create resources that depend on those CRDs (certificates, database clusters, gateways) |
| 2    | monitor | Deploy observability stack that scrapes the running workloads |

**Why this order matters.** Many shared-infrastructure resources are Custom
Resources (e.g., `Certificate`, `Cluster`, `ClusterIssuer`, `Gateway`). The
operators that define and reconcile those CRDs must be running before ArgoCD
attempts to create the CR instances. Deploying `core` at wave 0 guarantees that
cert-manager, CloudNative-PG, the MariaDB operator, Istio, and others are ready
before wave 1 begins.

The monitor chart lands last (wave 2) because Prometheus ServiceMonitors and
Probes target services created in earlier waves.

---

## Operator Template Pattern (core chart)

The `core` chart uses a data-driven approach: every operator is declared as an
entry in `values.yaml` under the `operators` map, and a single reusable partial
generates all the ArgoCD Applications.

### How it works

`charts/core/templates/operators.yaml` iterates over every key in
`.Values.operators`:

```yaml
{{- range $name, $_ := .Values.operators }}
{{- $out := include "homelab-core.operator" (list $name $) | trim }}
{{- if $out }}
{{ $out }}
{{- end }}
{{- end }}
```

For each entry it calls the `homelab-core.operator` partial defined in
`charts/core/templates/_operator.yaml`. That partial:

1. Looks up the operator config: `$operator := index $root.Values.operators $name`.
2. Skips disabled operators (`$operator.enabled` must be true).
3. Renders an ArgoCD `Application` resource with:
   - `metadata.name` set to the map key (e.g., `cert-manager`).
   - `spec.source` pointing at the operator's Helm repo (`repoURL`, `chart` or
     `path`, `version`).
   - `spec.source.helm.values` populated from the optional `values` sub-key.
   - `spec.destination.namespace` from the operator entry.
   - `spec.syncPolicy` defaulting to `global.syncPolicy` but overridable per
     operator.
   - Optional `ignoreDifferences` (used by Istio webhooks, for example).

### Adding a new operator

Add an entry to `charts/core/values.yaml`:

```yaml
operators:
  my-operator:
    enabled: true
    version: 1.0.0
    namespace: my-operator
    repoURL: https://example.com/charts
    chart: my-operator
    values:            # optional -- passed as helm values to the operator chart
      someKey: someVal
```

No new template file is needed. The loop picks it up automatically.

When using the umbrella chart, also map the operator to a feature flag in
`charts/homelab/templates/_helpers.tpl` so it can be toggled.

### Supported fields per operator

| Field              | Required | Description |
|--------------------|----------|-------------|
| `enabled`          | yes      | Toggle the operator on/off |
| `version`          | yes      | Chart version / Git revision |
| `namespace`        | yes      | Target namespace |
| `repoURL`          | yes      | Helm repo URL or OCI registry |
| `chart`            | no*      | Chart name within the repo |
| `path`             | no*      | Path within a Git repo (use instead of `chart`) |
| `values`           | no       | Helm value overrides passed to the operator chart |
| `syncPolicy`       | no       | Override `global.syncPolicy` for this operator |
| `ignoreDifferences`| no       | ArgoCD ignoreDifferences for flapping fields |

*One of `chart` or `path` must be set.

---

## Shared Chart Pattern

The `shared` chart takes a fundamentally different approach from `core`.

**core** deploys third-party charts indirectly: each operator entry becomes an
ArgoCD Application that points at an external Helm repository. ArgoCD fetches and
installs the chart independently.

**shared** renders Kubernetes resources directly as Helm templates inside the
chart itself. Files like `gateway.yaml`, `cert-issuer.yaml`,
`postgres-cluster.yaml`, and `authentik.yaml` emit raw Kubernetes manifests
(Gateway, ClusterIssuer, Cluster, Deployment, Service, etc.) that ArgoCD applies
as part of the single `shared` Application.

### Why the difference

Shared infrastructure resources are the platform's bespoke configuration layer.
They are not off-the-shelf charts with their own release cycles; they are
platform-specific manifests (a wildcard certificate, a specific Postgres cluster
configuration, an Istio Gateway with particular port mappings). Wrapping each one
in a separate ArgoCD Application would add overhead without benefit. Rendering
them in-line keeps the configuration co-located and version-controlled.

The `resources` map in `charts/shared/values.yaml` controls which pieces are
enabled, with each resource guarded by an `enabled` flag. These flags are set by
the umbrella chart's feature translation layer.

---

## Monitor Chart Pattern

The `monitor` chart is a hybrid. It uses both deployment strategies:

### ArgoCD Applications (external charts)

Large third-party stacks that have their own Helm charts are deployed as ArgoCD
Applications, just like operators in the core chart:

- **prometheus-operator** -- deployed via a `homelab-monitor.monitoringApp`
  partial. Entries live under `monitoring` in `values.yaml` and are iterated in
  `prometheus-operator.yaml`.
- **blackbox-exporter** -- deployed via a dedicated template
  (`blackbox-exporter-app.yaml`) with its own values block.

### Direct templates (cluster-specific resources)

Resources that are specific to the platform and have no upstream chart are
rendered directly:

| Template | What it creates |
|----------|-----------------|
| `prometheus-rules.yaml` | `PrometheusRule` with custom alert definitions |
| `blackbox-probes.yaml` | `Probe` CRs targeting internal services |
| `grafana-dashboard-*.yaml` | `ConfigMap` dashboards for Grafana |
| `istio-monitors.yaml` | `ServiceMonitor`/`PodMonitor` for Istio mesh telemetry |
| `ntfy-alertmanager.yaml` | Deployment for the ntfy-alertmanager webhook bridge |
| `virtual-service.yaml` | Istio `VirtualService` for Grafana ingress |
| `grafana-admin-secret.yaml` | `SealedSecret` for Grafana admin credentials |

---

## Value Override Chain

Values flow through three layers:

```
homelab/values.yaml          (1) Feature flags + platform config
    |
    | translated by _helpers.tpl
    v
ArgoCD Application spec      (2) Passed via spec.source.helm.values
    |
    | merged by Helm
    v
<child>/values.yaml          (3) Chart defaults
```

### How it works

The umbrella chart's helper templates (`homelab.operatorValues`,
`homelab.platformValues`, `homelab.monitoringValues`) translate feature flags
and platform config into the value structure each sub-chart expects. These
values are embedded in each ArgoCD Application's `spec.source.helm.values` field.

User overrides from the `overrides` section are deep-merged on top via
`mergeOverwrite`, then the entire block is passed to ArgoCD.

When ArgoCD renders a sub-chart, it merges these passed values with the
sub-chart's own `values.yaml` defaults. This means sub-chart defaults serve as
fallbacks — anything explicitly passed from the umbrella takes precedence.

For operators, the chain extends one more level:

```
homelab values -> core values -> operator entry .values -> upstream chart defaults
```

This keeps the homelab chart as the single source of truth for configuration
while letting each layer define sensible defaults.
