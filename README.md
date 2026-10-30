# Homelab Platform

> **Note:** This project powers my personal homelab. It is shared as a reference and starting point, not as a supported product. Breaking changes happen without warning and versions are not guaranteed to be stable. If you want to use this, **fork it** rather than depending on it directly.

A turnkey Kubernetes platform built with Helm and ArgoCD. Provides a complete, standards-based foundation for running applications on Kubernetes — from a single-node homelab to a production cluster.

**What you get:** GitOps deployment, service mesh with ingress, TLS certificates, OIDC authentication, managed databases, monitoring and alerting, security scanning, encrypted backups, and DNS management — all controlled through feature flags in a single values file.

**What you deploy on top:** Applications using the [`homelab-common`](#deploying-applications) library chart, which abstracts Kubernetes resources into a high-level interface, or raw Kubernetes manifests when you need full control.

## Helm Repository

CI disk layout and recovery are documented in [CI storage](docs/ci-storage.md).
PR and push chart checks run `mise install && scripts/ci/validate-charts.sh`.
They cover storage safety, public-only Coraza selection, WASM health scraping
and I/O alerts through rendered manifests and executable rule tests.
Core checks (`charts/core/tests/render.sh`) validate the rendered Falco exceptions:
24 approved executor/file tuples and negative cases for every identity field,
missing metadata, other files, build children and fontconfig shell log clearing.
Native Falco rule compilation and a representative build are verified separately
before and after rollout; tuple checks alone do not replay syscalls.

All charts are published to a Helm repository:

```bash
helm repo add homelab https://mortenolsen.pro/homelab-core/
helm repo update
helm search repo homelab/
```

Published charts:

| Chart | Description |
|-------|-------------|
| `homelab/homelab` | Umbrella chart — the entry point for deploying the platform |
| `homelab/homelab-core` | Operators sub-chart (wave 0) |
| `homelab/homelab-shared` | Platform resources sub-chart (wave 1) |
| `homelab/homelab-monitor` | Monitoring stack sub-chart (wave 2) |
| `homelab/homelab-common` | Library chart for deploying applications on the platform |

## Architecture

```
┌─────────────────────────────────────────────┐
│           homelab (Umbrella Chart)           │
│     Feature flags + platform config          │
│     Creates ArgoCD Applications              │
└──────────────┬──────────────────────────────┘
               │
       ┌───────┴──────────┬──────────────┐
       │                  │              │
   ┌───▼────────┐   ┌────▼─────────┐  ┌─▼──────────┐
   │  operators  │   │   platform   │  │  monitoring │
   │  (wave 0)   │   │   (wave 1)   │  │  (wave 2)  │
   │             │   │              │  │            │
   │  ArgoCD     │   │  Gateways    │  │ Prometheus │
   │  Istio      │   │  Certs       │  │ Grafana    │
   │  cert-mgr   │   │  Databases   │  │ Alertmgr   │
   │  CNPG       │   │  Auth        │  │ Blackbox   │
   │  Kyverno    │   │  DNS         │  │            │
   │  ...        │   │  Backups     │  │            │
   └─────────────┘   └──────────────┘  └────────────┘
```

Charts deploy in sync-wave order: operators first (installing CRDs), then platform resources that depend on those CRDs, then monitoring last.

### Dependency update ownership

ArgoCD owns platform deployments. Renovate's native `helm-values` manager tracks
container image values (including the local-path `helperImage` and disabled
Temporal `bootstrapImage`); custom Helm/OCI rules track the operator and monitoring
chart versions stored in values. The Istio gateway lookup uses
`https://blob.istio.io/istio-release/charts`; Istio and MariaDB chart groups remain
coordinated. Image dependencies are not duplicated by custom regex managers.
Woodpecker's repository cron owns the weekly Renovate cadence (Sunday 03:00 UTC).
There is no second package-level schedule that could prevent that run from
opening updates; updates still require review and are not auto-merged.

`operators.flux` makes the existing `flux-system` installation updateable through
the maintained [fluxcd-community `flux2` chart](https://fluxcd-community.github.io/helm-charts).
The initial pin is **2.16.4 / Flux 2.6.4**, matching the installed
`helm-controller:v1.3.0` and `source-controller:v1.6.2`, not an image upgrade.
The standard Helm custom manager discovers this chart's `version` / `repoURL` /
`chart` fields. Controller images and CRDs move together through reviewed chart
updates; there is no separate checked-in Flux install manifest to refresh.
Only source and Helm controllers are enabled; Kustomize, notifications and both
image controllers remain disabled. The umbrella `features.gitops` flag controls
the Flux Application alongside ArgoCD.

The chart maintains those Deployments, their service accounts, the source Service,
source/Helm CRDs, NetworkPolicies, and chart RBAC. A supplemental runtime role
retains the installed `serviceaccounts/token` create and `/livez/ping` HEAD
permissions absent from chart 2.16.4's shared controller role. CRDs carry
`Prune=false,Delete=false` so removing an Application cannot erase its APIs.
The preexisting `*-flux-system` ClusterRoles/Bindings have different names from
the chart's RBAC and are left untouched, not pruned or mass-deleted.

**First adoption:** compare the exact chart render and server-side dry-run before
allowing reconciliation. The inspected chart keeps Deployment names and immutable
selectors (`app: helm-controller` / `app: source-controller`), source Service name,
port and selector, resource requests/limits, security settings and cluster-wide
watch behavior. No Deployment recreation is expected. A source-controller
`Recreate` rollout still briefly interrupts its in-memory artifact server.
Do not use ArgoCD `Force`/`Replace` or delete the namespace/CRDs to adopt it.
The chart also supplies its standard pre-install Flux prerequisite-check Job.

After adoption, check `argocd app get flux`, both Deployment rollout statuses in
`flux-system`, the `source-controller` Service endpoints, established source/Helm
CRDs, and controller logs for discovery/RBAC errors. A temporary GitRepository
and HelmRepository/HelmRelease using an isolated namespace and an approved
disposable chart exercise both reconciliation paths; remove those smoke resources
after they reach Ready. Before adoption the inspected cluster had zero Flux
HelmReleases and source objects, so no application migration is required.


## Quick Start

### Prerequisites

- Kubernetes cluster (K3s, Kind, or any conformant distribution)
- [ArgoCD](https://argo-cd.readthedocs.io/) installed on the cluster
- [Helm](https://helm.sh/) 3.x
- A domain with DNS management (Cloudflare for default TLS setup)

### 1. Add the Helm repo

```bash
helm repo add homelab https://mortenolsen.pro/homelab-core/
helm repo update
```

### 2. Configure

Create a values file for your cluster:

```yaml
# my-cluster.yaml
source:
  repoUrl: https://github.com/<your-fork>/homelab-core.git
  targetRevision: main

platform:
  domain: example.com
  ip: 10.0.0.1
  gatewayAddress: ""  # set after first deploy — see note below
  email: admin@example.com
  timezone: UTC
  acme: staging  # use "prod" once DNS is verified

features:
  gitops: true
  serviceMesh: true
  certificates: true
  auth: true
  postgres: true
  mariadb: false       # disable what you don't need
  monitoring: true
  security: true
  secrets: true
  backup: true
  dns: true
  reflection: true
  reloader: true
  storage: true
  demo: false

backup:
  nfs:
    server: 10.0.0.2
    path: /backups

monitoring:
  ntfy:
    url: http://ntfy.prod.svc.cluster.local
    topic: alerts
```

### 3. Deploy

```bash
helm template homelab homelab/homelab -f my-cluster.yaml | kubectl apply -f -
```

Or from a local clone:

```bash
helm template homelab ./charts/homelab -f my-cluster.yaml | kubectl apply -f -
```

### 4. Set the gateway address (after first deploy)

After the initial deploy creates the Istio gateway Service, set `platform.gatewayAddress` to its ClusterIP:

```bash
kubectl get svc -n istio-ingress gateway -o jsonpath='{.spec.clusterIP}'
```

Add this to your values file and re-deploy. This enables STATIC ServiceEntry resolution, which prevents mesh-internal DNS hairpinning without generating DNS queries from every Envoy sidecar. Without this value, ServiceEntries are omitted and mesh-internal routing via public hostnames won't work (external routing is unaffected).

ArgoCD takes over from here — it creates the sub-chart Applications and syncs them in order.

### 4. Verify

```bash
kubectl get applications -n argocd
```

All applications should show `Synced` and `Healthy` within a few minutes.

## Features

Each feature flag controls one or more operators and the platform resources that depend on them.

| Feature | Flag | Operators | Platform Resources |
|---------|------|-----------|--------------------|
| **GitOps** | `gitops` | ArgoCD | — |
| **Service Mesh** | `serviceMesh` | Istio base, istiod | Ingress class, gateway pod, public/private Gateway CRs |
| **TLS Certificates** | `certificates` | cert-manager | Cluster issuer (Cloudflare DNS01), wildcard certificate |
| **Authentication** | `auth` | Authentik operator | Authentik server, OIDC provider |
| **PostgreSQL** | `postgres` | CloudNative-PG, postgres operator | Managed PostgreSQL cluster |
| **MariaDB** | `mariadb` | MariaDB operator + CRDs | — (databases created by apps) |
| **Monitoring** | `monitoring` | — | Prometheus, Grafana, Alertmanager, blackbox exporter |
| **Security** | `security` | Falco, Trivy, Kyverno | Runtime detection, vulnerability scanning, policy engine |
| **Secrets** | `secrets` | Sealed Secrets, External Secrets | — (secrets created by apps) |
| **Backup** | `backup` | VolSync | Encrypted PVC backups and PostgreSQL logical-dump/restic Job to NFS |
| **DNS** | `dns` | DNS operator | Pi-hole, DNS sidecar |
| **Reflection** | `reflection` | Reflector | Cross-namespace secret/configmap mirroring |
| **Reloader** | `reloader` | Reloader | Auto-restart pods on config changes |
| **Storage** | `storage` | — | Local-path storage class configuration |

See [Features](docs/features.md) for detailed documentation including dependency graph and configuration options.

### Overriding Defaults

For fine-grained control, use the `overrides` section to pass values directly to any sub-chart:

```yaml
overrides:
  operators:
    operators:
      istiod:
        version: "1.26.0"
  platform:
    resources:
      postgresCluster:
        instances: 3
        storage:
          size: 50Gi
  monitoring:
    monitoring:
      prometheus-operator:
        values:
          prometheus:
            prometheusSpec:
              retention: 60d
```

## Deploying Applications

The platform publishes `homelab-common`, a Helm library chart that provides high-level abstractions for deploying applications. A minimal app needs three files:

**Chart.yaml:**
```yaml
apiVersion: v2
version: 1.0.0
name: my-app
dependencies:
  - name: homelab-common
    version: ">=0.1.0"
    repository: https://mortenolsen.pro/homelab-core/
```

**templates/common.yaml:**
```yaml
{{ include "common.all" . }}
```

**values.yaml:**
```yaml
image:
  repository: ghcr.io/org/my-app
  tag: latest
subdomain: myapp
container:
  port: 8080
  healthProbe:
    type: httpGet
    path: /health
service:
  port: 80
virtualService:
  enabled: true
  gateways:
    private: true
```

Then build and deploy:

```bash
helm dependency build
helm template my-app . --set globals.domain=example.com | kubectl apply -f -
```

The common library handles Deployment, Service, VirtualService, PVC, DNS, OIDC, database provisioning, secrets, backups, and monitoring probes — all driven by values.

### What the common chart provides

| Template | Resource | Triggered by |
|----------|----------|-------------|
| `common.deployment` | Deployment | `image` + `deployment` |
| `common.service` | Service(s) | `service` |
| `common.pvc` | PersistentVolumeClaim(s) | `persistentVolumeClaims` |
| `common.virtualService` | Istio VirtualService | `virtualService.enabled` |
| `common.serviceEntry` | Istio ServiceEntry | `virtualService.enabled` |
| `common.dns` | DNSRecord | `dns.enabled` |
| `common.oidc` | AuthentikClient | `oidc.enabled` |
| `common.database` | PostgresDatabase | `database.enabled` |
| `common.externalSecrets` | ExternalSecret + Password | `externalSecrets` |
| `common.probe` | Blackbox Probe | `service` (auto) |
| `common.backup` | VolSync ReplicationSource | PVC with `backup: true` |

Use `{{ include "common.all" . }}` to render everything automatically, or include individual templates for more control.

## Local Development

This repo uses a Nix flake for development dependencies. With [Nix](https://nixos.org/) and [direnv](https://direnv.net/):

```bash
cd homelab-core        # direnv activates the Nix shell
make recreate          # Create Kind cluster + install ArgoCD + deploy stack
```

ArgoCD UI: `localhost:30080` (password in `argo-password.txt`).

See [Local Development](docs/local-development.md) for details.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | Chart hierarchy, sync waves, template patterns |
| [Features](docs/features.md) | Detailed feature reference with dependencies |
| [Networking](docs/networking.md) | Istio gateways, VirtualServices, DNS, TLS |
| [Authentication](docs/authentication.md) | Authentik OIDC setup and integration |
| [Secrets](docs/secrets.md) | External Secrets, Sealed Secrets, Reflector |
| [Monitoring](docs/monitoring.md) | Prometheus, alerts, Grafana, Blackbox probes |
| [Backups](docs/backups.md) | Volsync, PostgreSQL logical dumps, encrypted restic, schedules and restore procedures |
| [Disaster Recovery](docs/disaster-recovery.md) | Full cluster restore runbook |
| [Local Development](docs/local-development.md) | Nix shell, Kind, Makefile targets |

## Troubleshooting

```bash
# Check all applications
kubectl get applications -n argocd

# Inspect a specific application
argocd app get <name>

# Check operators
kubectl get applications -n argocd | grep -v Synced

# Certificate issues
kubectl get certificates -A
kubectl describe certificate -n shared wildcard-tls

# Render charts locally to debug
helm template homelab homelab/homelab -f my-cluster.yaml
helm template shared ./charts/shared
```
