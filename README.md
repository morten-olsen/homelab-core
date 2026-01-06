# Homelab Core

A Kubernetes-based homelab infrastructure stack built with Helm charts and ArgoCD. This project provides a complete, opinionated foundation for running a home server cluster with operators, shared resources, and GitOps-based deployment.

## Overview

This repository contains three main Helm charts that work together to provision and manage a Kubernetes homelab:

- **`homelab`** - Master chart that orchestrates the deployment of core and shared resources via ArgoCD
- **`core`** - Cluster operators and controllers (cert-manager, Istio, Kyverno, Longhorn, etc.)
- **`shared`** - Shared infrastructure resources (PostgreSQL cluster, OIDC service, HTTP gateways, certificates, etc.)

## Architecture

```
┌─────────────────────────────────────────┐
│         homelab (Master Chart)          │
│  Creates ArgoCD Applications            │
└──────────────┬──────────────────────────┘
               │
       ┌───────┴───────┐
       │               │
   ┌───▼───┐      ┌───▼────┐
   │ core  │      │ shared │
   │       │      │        │
   │ Sync  │      │ Sync   │
   │ Wave  │      │ Wave   │
   │   0   │      │   1    │
   └───────┘      └────────┘
```

### Chart Responsibilities

#### `homelab` Chart
The master chart that creates ArgoCD `Application` resources for deploying the `core` and `shared` charts. It manages:
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
   core:
     project: core
   shared:
     project: shared
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
core:
  project: core
shared:
  project: shared
```

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

## Deployment Order

The charts use ArgoCD sync waves to ensure proper deployment order:

1. **Wave 0**: `core` chart deploys operators and controllers
2. **Wave 1**: `shared` chart deploys shared infrastructure (depends on operators from core)

This ensures that operators like cert-manager and Istio are available before shared resources that depend on them.

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

See individual operator documentation for secret configuration.

## Monitoring and Observability

- **Trivy Operator** - Security scanning and vulnerability detection
- **Falco** - Runtime security monitoring (optional)
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
