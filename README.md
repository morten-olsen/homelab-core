# Homelab Core

A Kubernetes-based homelab infrastructure stack built with Helm charts and ArgoCD. This project provides a complete, opinionated foundation for running a home server cluster with operators, shared resources, and GitOps-based deployment.

## Overview

This repository contains four Helm charts that work together to provision and manage a Kubernetes homelab:

- **`homelab`** - Master chart that orchestrates deployment of the other three via ArgoCD
- **`core`** - Cluster operators and controllers (cert-manager, Istio, Kyverno, CloudNative-PG, etc.)
- **`shared`** - Shared infrastructure resources (gateways, certificates, PostgreSQL, Authentik, Pi-hole, etc.)
- **`monitor`** - Monitoring stack (Prometheus, Grafana, Alertmanager, Blackbox Exporter)

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

Charts deploy in sync-wave order: operators first, then shared infrastructure that depends on them, then monitoring last. See [Architecture](docs/architecture.md) for details.

## Key Design Decisions

- **Istio** for service mesh and ingress (sidecar injection)
- **CloudNative-PG** for PostgreSQL
- **cert-manager** with Cloudflare DNS01 for wildcard TLS certificates
- **ArgoCD** for GitOps (required)
- **local-path** for persistent storage (k3s)
- **Authentik** for OIDC/OAuth2 authentication
- **Volsync + restic** for encrypted backups to NFS

## Quick Start

This repo uses a Nix flake for development dependencies. With [Nix](https://nixos.org/) and [direnv](https://direnv.net/) installed, `cd` into the repo to get kubectl, helm, kind, k9s, and other tools automatically.

### Local Development (Kind)

```bash
make recreate    # Create Kind cluster + install ArgoCD + deploy stack
```

ArgoCD UI is available at `localhost:30080` (password in `argo-password.txt`). See [Local Development](docs/local-development.md) for details.

### Production Deployment

1. Fork this repository
2. Update `charts/homelab/values.yaml` with your repo URL
3. Update `charts/shared/values.yaml` with your domain and email
4. Deploy the homelab chart:
   ```bash
   helm template homelab ./charts/homelab | kubectl apply -f -
   ```

### Configuration

Each chart has a `values.yaml` with inline comments. The homelab chart can also pass value overrides to child charts via the ArgoCD Application spec — see `charts/homelab/values.yaml` for examples.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | Chart hierarchy, sync waves, template patterns |
| [Networking](docs/networking.md) | Istio gateways, VirtualServices, DNS, TLS |
| [Secrets](docs/secrets.md) | External Secrets, Sealed Secrets, Reflector |
| [Authentication](docs/authentication.md) | Authentik OIDC setup and integration |
| [Monitoring](docs/monitoring.md) | Prometheus, alerts, Grafana, Blackbox probes |
| [Backups](docs/backups.md) | Volsync + restic, schedules, disaster recovery |
| [Local Development](docs/local-development.md) | Nix shell, Kind, Makefile targets, scripts |

## Troubleshooting

### ArgoCD Applications Not Syncing

```bash
kubectl get applications -n argocd
argocd app get core
argocd app get shared
argocd repo list
```

### Operators Not Installing

```bash
kubectl get appproject -n argocd
kubectl get applications -n argocd | grep <operator-name>
```

### Certificate Issues

```bash
kubectl get pods -n cert-manager
kubectl get certificates -n shared
kubectl describe certificate -n shared wildcard-tls
```

## License

[Add your license here]
