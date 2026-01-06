# Homelab Core

A Kubernetes-based homelab infrastructure stack built with Helm charts and ArgoCD. This project provides a complete, opinionated foundation for running a home server cluster with operators, shared resources, and GitOps-based deployment.

## Overview

This repository contains four main Helm charts that work together to provision and manage a Kubernetes homelab:

- **`homelab`** - Master chart that orchestrates the deployment of core, shared, and monitoring resources via ArgoCD
- **`core`** - Cluster operators and controllers (cert-manager, Istio, Kyverno, Longhorn, etc.)
- **`shared`** - Shared infrastructure resources (PostgreSQL cluster, OIDC service, HTTP gateways, certificates, etc.)
- **`monitor`** - Monitoring stack (Prometheus, Grafana, Alertmanager, and related components)

## Architecture

```
┌─────────────────────────────────────────┐
│         homelab (Master Chart)          │
│  Creates ArgoCD Applications            │
└──────────────┬──────────────────────────┘
               │
       ┌───────┴───────┬──────────┐
       │               │          │
   ┌───▼───┐      ┌───▼────┐  ┌──▼──────┐
   │ core  │      │ shared │  │ monitor │
   │       │      │        │  │         │
   │ Sync  │      │ Sync   │  │ Sync    │
   │ Wave  │      │ Wave   │  │ Wave    │
   │   0   │      │   1    │  │   2     │
   └───────┘      └────────┘  └─────────┘
```

### Chart Responsibilities

#### `homelab` Chart
The master chart that creates ArgoCD `Application` resources for deploying the `core`, `shared`, and `monitor` charts. It manages:
- ArgoCD AppProjects for organizing applications
- Application definitions with proper sync waves
- Repository and revision configuration

#### `core` Chart
Installs and manages cluster-level operators and controllers:
- **cert-manager** - Certificate management
- **Istio** - Service mesh (base + istiod)
- **Kyverno** - Policy engine
- **Longhorn** - Distributed block storage
- **CloudNative-PG** - PostgreSQL operator
- **External Secrets Operator** - Secret management
- **Sealed Secrets** - Encrypted secrets
- **Authentik Operator** - OIDC provider
- **Trivy Operator** - Security scanning
- **Reflector** - Secret/ConfigMap reflection
- **DNS Operator** - DNS management
- **MariaDB Operator** - MySQL/MariaDB operator
- And more...

#### `shared` Chart
Provides shared infrastructure resources used by applications:
- **Istio Gateways** - Public and private ingress gateways
- **Certificates** - Wildcard TLS certificates via cert-manager
- **PostgreSQL Cluster** - Shared database cluster
- **Authentik** - OIDC/OAuth2 provider instance
- **Pi-hole** - DNS filtering and ad blocking
- **Storage Classes** - Longhorn-based storage
- **Ingress Classes** - Kubernetes ingress configuration

#### `monitor` Chart
Deploys the monitoring stack for observability:
- **Prometheus Operator** - Manages Prometheus, Alertmanager, and related components
- **Prometheus** - Metrics collection and storage
- **Grafana** - Visualization and dashboards
- **Alertmanager** - Alert routing and notification
- **Node Exporter** - Node-level metrics
- **Kube State Metrics** - Kubernetes object metrics

## Prerequisites

- Kubernetes cluster (1.24+)
- **ArgoCD** installed and running in the `argocd` namespace
- `kubectl` configured with cluster access
- `helm` 3.x installed
- Git repository access (for ArgoCD to sync)

## Quick Start

### Option 1: Deploy via Helm Template

1. Clone this repository:
   ```bash
   git clone <repository-url>
   cd homelab-core
   ```

2. Customize values in `charts/homelab/values.yaml`:
   ```yaml
   repoUrl: https://github.com/your-username/homelab-core.git
   targetRevision: main  # Git branch, tag, or commit
   revision: main
   core:
     project: core
   shared:
     project: shared
   monitor:
     project: monitor
   ```

3. Template and apply the chart:
   ```bash
   helm template homelab ./charts/homelab | kubectl apply -f -
   ```

### Option 2: Deploy via ArgoCD Application

1. Create an ArgoCD Application pointing to this repository:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: homelab
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/your-username/homelab-core.git
       targetRevision: main
       path: charts/homelab
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - ServerSideApply=true
         - CreateNamespace=true
   ```

2. Apply the Application:
   ```bash
   kubectl apply -f homelab-app.yaml
   ```

## Configuration

### Homelab Chart Values

Edit `charts/homelab/values.yaml`:

```yaml
repoUrl: https://github.com/your-username/homelab-core.git
targetRevision: main  # or specific branch/tag
revision: main

core:
  project: core
  # Optional: Override values for the core chart
  values:
    global:
      syncPolicy:
        automated:
          prune: false
    operators:
      cert-manager:
        enabled: true
        values:
          extraArgs:
            - --dns01-recursive-nameservers-only

shared:
  project: shared
  # Optional: Override values for the shared chart
  values:
    global:
      domain: yourdomain.com
      email: your-email@example.com
    resources:
      gateway:
        enabled: true

monitor:
  project: monitor
  # Optional: Override values for the monitor chart
  values:
    monitoring:
      prometheus-operator:
        enabled: true
        values:
          prometheus:
            prometheusSpec:
              retention: 60d
```

**Value Overrides**: You can override any values from the `core`, `shared`, or `monitor` charts by adding a `values` section under each chart configuration. These values will be merged with the default values from each chart's `values.yaml` file, allowing you to customize the deployment without modifying the chart files directly.

### Core Chart Values

Edit `charts/core/values.yaml` to enable/disable operators:

```yaml
global:
  project: core
  syncPolicy:
    automated:
      prune: true
      selfHeal: true

operators:
  cert-manager:
    enabled: true
    version: 1.19.2
    # ... operator-specific configuration
```

### Shared Chart Values

Edit `charts/shared/values.yaml` to configure shared resources:

```yaml
global:
  project: shared
  domain: yourdomain.com
  email: your-email@example.com
  acme: prod  # or staging

resources:
  gateway:
    enabled: true
  certIssuer:
    enabled: true
  postgresCluster:
    enabled: true
  authentik:
    enabled: true
    subdomain: auth
```

### Monitor Chart Values

Edit `charts/monitor/values.yaml` to configure the monitoring stack:

```yaml
global:
  project: monitor
  syncPolicy:
    automated:
      prune: true
      selfHeal: true

monitoring:
  prometheus-operator:
    enabled: true
    version: 68.0.0
    namespace: monitoring
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    values:
      prometheus:
        prometheusSpec:
          retention: 30d
          storageSpec:
            volumeClaimTemplate:
              spec:
                storageClassName: longhorn
                resources:
                  requests:
                    storage: 50Gi
      grafana:
        enabled: true
        # Option 1: Plain text password (not recommended)
        # adminPassword: admin
        
        # Option 2: Use Kubernetes secret (recommended)
        # Create secret: kubectl create secret generic grafana-admin -n monitoring --from-literal=admin-user=admin --from-literal=admin-password=your-secure-password
        admin:
          existingSecret: grafana-admin
          userKey: admin-user
          passwordKey: admin-password
        persistence:
          enabled: true
          storageClassName: longhorn
          size: 10Gi
      alertmanager:
        enabled: true
```

## Deployment Order

The charts use ArgoCD sync waves to ensure proper deployment order:

1. **Wave 0**: `core` chart deploys operators and controllers
2. **Wave 1**: `shared` chart deploys shared infrastructure (depends on operators from core)
3. **Wave 2**: `monitor` chart deploys monitoring stack (depends on core and shared)

This ensures that operators like cert-manager and Istio are available before shared resources that depend on them, and monitoring is deployed after the infrastructure is ready.

## Customization

This project is **heavily opinionated** and designed for home server use. Key design decisions:

- Uses Istio for service mesh and ingress
- Prefers CloudNative-PG for PostgreSQL
- Uses cert-manager with Cloudflare DNS for certificates
- Assumes ArgoCD for GitOps workflows
- Uses Longhorn for persistent storage
- Integrates Authentik for authentication

To customize:

1. Fork this repository
2. Modify values files in each chart
3. Adjust templates as needed
4. Update the repository URL in `homelab/values.yaml`

## Secrets Management

This project uses multiple secret management approaches:

- **Sealed Secrets** - For encrypting secrets in Git
- **External Secrets Operator** - For syncing secrets from external sources
- **Reflector** - For copying secrets across namespaces
- **Kubernetes Secrets** - Direct secret references (e.g., Grafana admin password)

### Grafana Admin Password

The Grafana admin password is automatically generated using External Secrets Operator by default. The monitor chart creates:

1. **Automatic Secret Generation (Default)**:
   - An ExternalSecret resource that uses a Password generator to create a random 32-character password
   - The secret `grafana-admin` is automatically created in the `monitoring` namespace
   - Username: `admin`
   - Password: Randomly generated (base64 encoded, 32 characters)
   
   This is enabled by default via `resources.grafanaAdminSecret.enabled: true` in `charts/monitor/values.yaml`.
   
   To retrieve the password after deployment:
   ```bash
   kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
   ```

2. **Manual Secret Creation**: If you prefer to create the secret manually:
   ```bash
   kubectl create secret generic grafana-admin -n monitoring \
     --from-literal=admin-user=admin \
     --from-literal=admin-password=your-secure-password
   ```
   
   Then disable the ExternalSecret:
   ```yaml
   resources:
     grafanaAdminSecret:
       enabled: false
   ```

3. **Plain Text (Not Recommended)**: Only for development/testing:
   ```yaml
   grafana:
     adminPassword: admin
   ```
   Note: If using plain text, disable the ExternalSecret generation.

See individual operator documentation for secret configuration.

## Monitoring and Observability

The `monitor` chart provides comprehensive monitoring capabilities:

- **Prometheus** - Metrics collection, storage, and querying
- **Grafana** - Visualization dashboards and alerting UI
- **Alertmanager** - Alert routing and notification management
- **Node Exporter** - Node-level system metrics
- **Kube State Metrics** - Kubernetes object metrics

Additional observability tools:

- **Trivy Operator** - Security scanning and vulnerability detection (in `core` chart)
- **Falco** - Runtime security monitoring (optional, in `core` chart)
- ArgoCD provides application health and sync status

## Troubleshooting

### ArgoCD Applications Not Syncing

1. Check ArgoCD application status:
   ```bash
   kubectl get applications -n argocd
   ```

2. View application details:
   ```bash
   argocd app get core
   argocd app get shared
   ```

3. Check repository access:
   ```bash
   argocd repo list
   ```

### Operators Not Installing

1. Verify ArgoCD project permissions:
   ```bash
   kubectl get appproject -n argocd
   ```

2. Check operator application status:
   ```bash
   kubectl get applications -n argocd | grep <operator-name>
   ```

### Certificate Issues

1. Verify cert-manager is running:
   ```bash
   kubectl get pods -n cert-manager
   ```

2. Check certificate status:
   ```bash
   kubectl get certificates -n shared
   kubectl describe certificate -n shared wildcard-tls
   ```

## Contributing

This is a personal homelab project, but contributions and suggestions are welcome. Please:

1. Open an issue to discuss changes
2. Fork the repository
3. Make your changes
4. Submit a pull request

## License

[Add your license here]

## Acknowledgments

Built with:
- [ArgoCD](https://argoproj.github.io/cd/)
- [Istio](https://istio.io/)
- [cert-manager](https://cert-manager.io/)
- [CloudNative-PG](https://cloudnative-pg.io/)
- [Longhorn](https://longhorn.io/)
- And many other excellent open-source projects
