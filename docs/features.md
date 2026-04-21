# Feature Reference

The homelab platform is configured through feature flags in the umbrella chart's `values.yaml`. Each feature controls one or more **operators** (installed in wave 0) and **platform resources** (installed in wave 1), ensuring correct dependency ordering.

## Feature Map

### `gitops` — GitOps Controller

| Component | Type | Chart |
|-----------|------|-------|
| ArgoCD | Operator | `argo-cd` from argoproj.github.io |

ArgoCD is the deployment mechanism for the entire platform. Disabling this removes the ArgoCD operator — only do this if you manage ArgoCD separately.

### `serviceMesh` — Service Mesh and Ingress

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| Istio base | Operator | `base` from istio-release |
| istiod | Operator | `istiod` from istio-release |
| Ingress class | Resource | IngressClass for Istio |
| Gateway pod | Resource | Istio gateway Deployment (istio-ingress namespace) |
| Public Gateway | Resource | Gateway CR — external traffic (ports 18080/18443) |
| Private Gateway | Resource | Gateway CR — internal traffic (ports 80/443) |

Istio provides sidecar-injected service mesh with mTLS, traffic management via VirtualServices, and ingress through the gateway pod. The dual-gateway pattern separates public (internet-facing) and private (LAN-only) traffic.

**Depends on:** `certificates` (gateways reference the wildcard TLS secret), `reflection` (mirrors the TLS secret to the gateway namespace).

### `certificates` — TLS Certificate Management

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| cert-manager | Operator | `cert-manager` from quay.io/jetstack |
| Cluster issuer | Resource | ClusterIssuer (Cloudflare DNS01 ACME) |
| Wildcard certificate | Resource | Certificate for `*.{domain}` |

Provides automatic TLS certificate issuance and renewal. The default configuration uses Cloudflare DNS01 challenge, which requires a Cloudflare API token stored as a Secret.

**Configuration:** Set `platform.acme: staging` for testing, `prod` for real certificates.

### `auth` — Identity and Authentication

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| Authentik operator | Operator | `authentik-operator` (custom) |
| Authentik server | Resource | AuthentikServer CR + VirtualService |

Authentik provides OIDC/OAuth2 authentication. Applications request OIDC clients via the `AuthentikClient` CRD (handled by the common library chart's `oidc` feature).

**Depends on:** `postgres` (Authentik stores its data in PostgreSQL), `serviceMesh` (VirtualService for routing), `certificates` (TLS).

### `postgres` — PostgreSQL Databases

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| CloudNative-PG | Operator | `cloudnative-pg` from cloudnative-pg.github.io |
| Postgres operator | Operator | `postgres-operator` (custom, provides PostgresDatabase CRD) |
| PostgreSQL cluster | Resource | CloudNative-PG Cluster (1 instance, 10Gi default) |

Provides a managed PostgreSQL cluster. Applications request databases via the `PostgresDatabase` CRD (handled by the common library chart's `database` feature), which creates the database, user, and connection secret automatically.

### `mariadb` — MariaDB Databases

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| MariaDB CRDs | Operator | `mariadb-operator-crds` from helm.mariadb.com |
| MariaDB operator | Operator | `mariadb-operator` from helm.mariadb.com |

Installs the MariaDB operator. Databases are created by applications as needed.

### `monitoring` — Observability Stack

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| Prometheus | Application (wave 2) | `kube-prometheus-stack` |
| Grafana | Included | Dashboards + persistence |
| Alertmanager | Included | Alert routing to ntfy |
| Blackbox Exporter | Application (wave 2) | HTTP probe endpoints |
| Grafana dashboards | Resources | Backups, Falco, HTTP, Trivy |
| Prometheus rules | Resources | Custom homelab alert rules |
| Istio monitors | Resources | ServiceMonitor/PodMonitor for mesh |

This feature controls the entire monitoring sub-chart (wave 2). When disabled, no monitoring Application is created.

**Configuration:**
```yaml
monitoring:
  ntfy:
    url: http://ntfy.prod.svc.cluster.local
    topic: homelab-alerts
```

### `security` — Security Scanning and Policy

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| Falco | Operator | `falco` from falcosecurity.github.io |
| Trivy | Operator | `trivy-operator` from aquasecurity.github.io |
| Kyverno | Operator | `kyverno` from kyverno.github.io |

- **Falco**: Runtime threat detection using eBPF, alerts forwarded to Alertmanager
- **Trivy**: Vulnerability scanning for container images
- **Kyverno**: Policy engine for admission control

### `secrets` — Secret Management

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| External Secrets Operator | Operator | `external-secrets` from charts.external-secrets.io |
| Sealed Secrets | Operator | `sealed-secrets` from bitnami-labs.github.io |

Two complementary approaches: External Secrets for generating secrets (passwords, API keys) and syncing from external stores; Sealed Secrets for encrypting secrets that can be safely committed to git.

### `backup` — Volume Backup

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| VolSync | Operator | `volsync` from backube.github.io |
| Backup resources | Resources | ReplicationSource CRs for PVCs |

VolSync replicates PVCs to NFS using restic encryption. Backup schedules are defined per-PVC in the platform and monitoring sub-charts. Applications can also declare backups via the common library chart.

**Configuration:**
```yaml
backup:
  nfs:
    server: 10.0.0.2
    path: /backups
```

### `dns` — DNS Management

| Component | Type | Chart / Resource |
|-----------|------|-----------------|
| DNS operator | Operator | `dns-operator` (custom) |
| Pi-hole | Resource | Deployment + Service (DNS server) |
| Pi-hole DNS sidecar | Resource | Deployment (DNS synchronization) |

Pi-hole provides DNS-level ad blocking and local DNS resolution. The DNS operator manages `DNSRecord` CRDs for automatic DNS registration (used by the common library chart's `dns` feature).

### `reflection` — Cross-namespace Reflection

| Component | Type | Chart |
|-----------|------|-------|
| Reflector | Operator | `reflector` from ghcr.io/emberstack |

Mirrors Secrets and ConfigMaps across namespaces based on annotations. Critical for sharing the wildcard TLS certificate from the shared namespace to the istio-ingress namespace.

### `reloader` — Config Change Restart

| Component | Type | Chart |
|-----------|------|-------|
| Reloader | Operator | `reloader` from stakater.github.io |

Watches ConfigMaps and Secrets, automatically triggers rolling restarts of Deployments/StatefulSets when referenced configs change.

### `storage` — Storage Class

| Component | Type | Resource |
|-----------|------|----------|
| Storage class | Resource | ConfigMap for local-path-provisioner |

Configures the local-path storage class for K3s. Only relevant for K3s-based clusters.

### `demo` — Demo Applications

| Component | Type | Resource |
|-----------|------|----------|
| Demo | Application (wave 2) | Sample applications |

Demo applications for testing the platform. Safe to disable in production.

## Dependency Graph

```
certificates ◄── serviceMesh (gateways need TLS secret)
     │                │
     │                ├── auth (VirtualService routing)
     │                └── monitoring (VirtualService for Grafana)
     │
reflection ◄── serviceMesh (mirrors TLS cert to gateway namespace)

postgres ◄── auth (Authentik database)
         ◄── [applications] (PostgresDatabase CRDs)

secrets ◄── [applications] (ExternalSecret CRDs)

backup ◄── [applications] (ReplicationSource CRDs)
```

Features can be disabled independently, but disabling a dependency will break features that depend on it. The platform does not enforce this — you are responsible for ensuring consistency.
