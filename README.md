# Homelab Platform

A turnkey Kubernetes platform built with Helm and ArgoCD. Provides a complete, standards-based foundation for running applications on Kubernetes — from a single-node homelab to a production cluster.

**What you get:** GitOps deployment, service mesh with ingress, TLS certificates, OIDC authentication, managed databases, monitoring and alerting, security scanning, encrypted backups, and DNS management — all controlled through feature flags in a single values file.

**What you deploy on top:** Applications using the [homelab-common](https://github.com/morten-olsen/homelab-apps) library chart, which abstracts Kubernetes resources into a high-level interface, or raw Kubernetes manifests when you need full control.

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

## Quick Start

### Prerequisites

- Kubernetes cluster (K3s, Kind, or any conformant distribution)
- [ArgoCD](https://argo-cd.readthedocs.io/) installed on the cluster
- [Helm](https://helm.sh/) 3.x
- A domain with DNS management (Cloudflare for default TLS setup)

### 1. Configure

Create a values file for your cluster:

```yaml
# my-cluster.yaml
source:
  repoUrl: https://github.com/<your-fork>/homelab-core.git
  targetRevision: main

platform:
  domain: example.com
  ip: 10.0.0.1
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

### 2. Deploy

```bash
helm template homelab ./charts/homelab -f my-cluster.yaml | kubectl apply -f -
```

ArgoCD takes over from here — it creates the sub-chart Applications and syncs them in order.

### 3. Verify

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
| **Backup** | `backup` | VolSync | Restic-based PVC backup to NFS |
| **DNS** | `dns` | DNS operator | Pi-hole, DNS sidecar |
| **Reflection** | `reflection` | Reflector | Cross-namespace secret/configmap mirroring |
| **Reloader** | `reloader` | Reloader | Auto-restart pods on config changes |
| **Storage** | `storage` | — | Local-path storage class configuration |

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

The platform includes [homelab-common](https://github.com/morten-olsen/homelab-apps), a Helm library chart that provides high-level abstractions for deploying applications. A minimal app needs three files:

**Chart.yaml:**
```yaml
apiVersion: v2
version: 1.0.0
name: my-app
dependencies:
  - name: homelab-common
    version: 0.1.0
    repository: https://morten-olsen.github.io/homelab-apps
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

The common library handles Deployment, Service, VirtualService, PVC, DNS, OIDC, database provisioning, secrets, backups, and monitoring probes — all driven by values.

See the [common chart README](https://github.com/morten-olsen/homelab-apps/blob/main/apps/common/README.md) for the full values reference.

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
| [Backups](docs/backups.md) | Volsync + restic, schedules, restore procedures |
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
helm template homelab ./charts/homelab -f my-cluster.yaml
helm template shared ./charts/shared
```
