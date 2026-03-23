# Homelab Core Architecture

## Chart Hierarchy

The repo contains four Helm charts under `charts/`:

```
charts/
  homelab/      Orchestrator -- the only chart deployed directly to ArgoCD
  core/         Operators    -- CRD controllers and cluster-wide tooling
  shared/       Shared infra -- networking, TLS, databases, DNS, auth
  monitor/      Observability -- Prometheus stack, Grafana, alerting, probes
```

The `homelab` chart is the single root Application registered in ArgoCD. It does
not deploy any workloads itself. Instead, its templates (`core.yaml`,
`shared.yaml`, `monitor.yaml`) each create:

1. An ArgoCD **AppProject** (one per child chart).
2. An ArgoCD **Application** that points back to this Git repo at the
   corresponding `charts/<name>` path.

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
        +-- monitor (Application, wave 2)
              +-- prometheus-operator (Application)
              +-- blackbox-exporter   (Application)
              +-- PrometheusRule, Probe, ConfigMap dashboards, ...
              (mix of ArgoCD Applications and direct templates)
```

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

Shared infrastructure resources are bespoke to this homelab. They are not
off-the-shelf charts with their own release cycles; they are cluster-specific
manifests (a wildcard certificate, a specific Postgres cluster configuration, an
Istio Gateway with particular port mappings). Wrapping each one in a separate
ArgoCD Application would add overhead without benefit. Rendering them in-line
keeps the configuration co-located and version-controlled in one place.

The `resources` map in `charts/shared/values.yaml` controls which pieces are
enabled, with each resource guarded by an `enabled` flag.

---

## Monitor Chart Pattern

The `monitor` chart is a hybrid. It uses both deployment strategies:

### ArgoCD Applications (external charts)

Large third-party stacks that have their own Helm charts are deployed as ArgoCD
Applications, just like operators in the core chart:

- **prometheus-operator** -- deployed via a `homelab-monitor.monitoringApp`
  partial (structurally identical to the core operator partial). Entries live
  under `monitoring` in `values.yaml` and are iterated in
  `prometheus-operator.yaml`.
- **blackbox-exporter** -- deployed via a dedicated template
  (`blackbox-exporter-app.yaml`) with its own values block.

### Direct templates (cluster-specific resources)

Resources that are specific to this cluster and have no upstream chart are
rendered directly:

| Template | What it creates |
|----------|-----------------|
| `prometheus-rules.yaml` | `PrometheusRule` with custom alert definitions (disk, pod, certificate expiry) |
| `blackbox-probes.yaml` | `Probe` CRs targeting internal services for uptime monitoring |
| `grafana-dashboard-http.yaml` | `ConfigMap` with a Grafana dashboard JSON for HTTP probes |
| `grafana-dashboard-trivy.yaml` | `ConfigMap` with a Grafana dashboard JSON for Trivy scan results |
| `istio-monitors.yaml` | `ServiceMonitor`/`PodMonitor` for Istio mesh telemetry |
| `ntfy-alertmanager.yaml` | Deployment for the ntfy-alertmanager webhook bridge |
| `virtual-service.yaml` | Istio `VirtualService` for Grafana ingress |
| `grafana-admin-secret.yaml` | `SealedSecret` for the Grafana admin credentials |

This hybrid approach lets the chart leverage battle-tested upstream charts
(kube-prometheus-stack, blackbox-exporter) while keeping custom alerting rules,
dashboards, and probes as version-controlled templates that are easy to review
and modify.

---

## Value Override Chain

Values flow through three layers:

```
homelab/values.yaml          (1) Top-level overrides
    |
    v
ArgoCD Application spec      (2) Passed via spec.source.helm.values
    |
    v
<child>/values.yaml          (3) Chart defaults
```

### How it works

Each child Application template in the homelab chart injects values into the
ArgoCD Application's `spec.source.helm.values` field. For example, from
`charts/homelab/templates/core.yaml`:

```yaml
source:
  repoURL: "{{ .Values.repoUrl }}"
  targetRevision: "{{ .Values.revision }}"
  path: charts/core
  helm:
    values: |
      project: "{{ .Values.core.project }}"
      {{- if .Values.core.values }}
      {{- toYaml .Values.core.values | nindent 8 }}
      {{- end }}
```

This means you can override any value in the core, shared, or monitor chart by
setting it under the corresponding key in `charts/homelab/values.yaml`:

```yaml
# charts/homelab/values.yaml
core:
  project: core
  values:                          # <-- everything here merges into core's values
    operators:
      cert-manager:
        enabled: true
        values:
          extraArgs:
            - --dns01-recursive-nameservers-only

shared:
  project: shared
  values:
    global:
      domain: example.com

monitor:
  project: monitor
  values:
    monitoring:
      prometheus-operator:
        values:
          prometheus:
            prometheusSpec:
              retention: 60d
```

The same pattern repeats one level deeper: operator entries in the core chart
pass their `values` sub-key into the ArgoCD Application they generate, which
means the full chain can be up to four layers deep:

```
homelab values -> core values -> operator entry .values -> upstream chart defaults
```

This keeps the homelab chart as the single source of truth for environment-specific
configuration while letting each child chart define sensible defaults.
