# Homelab Core

This repository contains ArgoCD Application definitions and configurations for deploying the core infrastructure of a home server setup.

## Overview

This project uses ArgoCD to manage GitOps-based deployments of various applications and services for a home lab environment. The repository follows the App-of-Apps pattern, where a root application manages multiple child applications.

## Repository Structure

```
.
├── apps/              # ArgoCD Application definitions
│   ├── app-of-apps.yaml
│   └── example-app.yaml
├── bootstrap/         # Bootstrap ArgoCD installation
│   ├── argocd.yaml    # Direct YAML (deprecated, use Helm chart)
│   └── values.yaml    # Helm values for bootstrap
├── charts/            # Helm charts
│   └── app-of-apps/   # App-of-Apps Helm chart
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── app-of-apps.yaml
│           └── _helpers.tpl
├── e2e/              # End-to-end test scripts
│   ├── setup-kind.sh
│   ├── install-argocd.sh
│   ├── deploy-bootstrap.sh
│   ├── verify-deployment.sh
│   ├── cleanup.sh
│   └── apply-apps-local.sh
├── .devcontainer/    # Dev container configuration
│   ├── devcontainer.json
│   └── README.md
├── Makefile          # Convenience commands for testing
├── flake.nix         # Nix flake for dependency management
├── README.md         # User-facing documentation
└── AGENTS.md         # AI agent documentation and conventions
```

## Prerequisites

You can set up the development environment in three ways:

### Option 1: Nix Flake (Recommended for Nix users)

If you have [Nix](https://nixos.org/download.html) installed with [Flakes](https://nixos.wiki/wiki/Flakes) enabled:

```bash
# Enter the development shell (installs all dependencies)
nix develop

# Or use direnv for automatic activation (recommended)
# The .envrc file is already configured
direnv allow
```

With direnv, the development environment will automatically activate when you enter the directory.

### Option 2: Dev Container (Recommended for VS Code/Cursor users)

If you use VS Code or Cursor:

1. Open the repository in your editor
2. When prompted, click "Reopen in Container"
3. Or use Command Palette: "Dev Containers: Reopen in Container"

All dependencies are pre-installed. See [.devcontainer/README.md](.devcontainer/README.md) for details.

### Option 3: Manual Installation

Install the following tools manually:

- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [helm](https://helm.sh/docs/intro/install/)
- [make](https://www.gnu.org/software/make/)
- [Docker](https://docs.docker.com/get-docker/) (required for Kind)

## Quick Start

### Running E2E Tests

To run the complete end-to-end test suite:

```bash
make test-e2e
```

This will:
1. Create a Kind cluster
2. Install ArgoCD
3. Deploy the bootstrap application
4. Verify all applications are healthy
5. Clean up the cluster

### Individual Test Steps

You can also run individual steps:

```bash
# Create Kind cluster
make setup-kind

# Install ArgoCD
make install-argocd

# Deploy bootstrap application
make deploy-bootstrap

# Verify deployment
make verify

# Cleanup
make cleanup
```

## Configuration

### Deploying the App-of-Apps

The app-of-apps can be deployed using either:

#### Option 1: Helm Chart (Recommended)

```bash
# Using default values
helm install app-of-apps ./charts/app-of-apps -n argocd --create-namespace

# Using custom values
helm install app-of-apps ./charts/app-of-apps \
  -f bootstrap/values.yaml \
  -n argocd \
  --create-namespace

# Or override specific values
helm install app-of-apps ./charts/app-of-apps \
  --set repo.url=https://github.com/your-username/homelab-core \
  --set repo.targetRevision=main \
  -n argocd \
  --create-namespace
```

#### Option 2: Direct YAML (Legacy)

```bash
kubectl apply -f bootstrap/argocd.yaml
```

### Customizing Cluster Name

You can customize the Kind cluster name:

```bash
make test-e2e CLUSTER_NAME=my-custom-cluster
```

### Configuring Repository URL

For the e2e tests to work properly, ArgoCD needs to access your Git repository. The scripts will automatically detect the repository URL from your git remote. You can also override it:

```bash
make deploy-bootstrap REPO_URL=https://github.com/your-username/homelab-core
```

The e2e scripts use Helm by default. To use direct YAML instead:

```bash
USE_HELM=false make deploy-bootstrap REPO_URL=https://github.com/your-username/homelab-core
```

**Note:** For local testing without a remote Git repository, you'll need to either:
1. Set up a Git remote pointing to your repository
2. Use a local Git server setup (advanced)
3. Manually sync applications using `argocd app sync` after applying manifests

### ArgoCD Access

After running `make install-argocd`, ArgoCD UI will be available at:
- HTTP: http://localhost:30080
- HTTPS: https://localhost:30443

The default admin password can be retrieved with:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Adding Applications

To add a new application to your homelab:

1. Create a new Application manifest in the `apps/` directory
2. The `app-of-apps` application (managed by the Helm chart) will automatically discover and deploy it
3. Update `charts/app-of-apps/values.yaml` if you need to customize the application's sync policy or other settings

Example application structure:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.example.com
    chart: my-chart
    targetRevision: 1.0.0
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## Development

### Testing Locally

1. Ensure all prerequisites are installed
2. Run `make test-e2e` to verify your changes
3. Check the ArgoCD UI to inspect application status

### Documentation Maintenance

**Important**: This repository maintains two key documentation files:

- **README.md** - User-facing documentation (this file)
- **AGENTS.md** - AI agent documentation with project conventions and workflows

**When making changes to the project:**

1. **Always update relevant documentation**:
   - Update `README.md` for user-facing changes (usage, examples, new features)
   - Update `AGENTS.md` for structural changes, conventions, or workflow modifications
   - Keep both files synchronized with the actual codebase

2. **When discovering discrepancies**:
   - If code and documentation don't match, fix the discrepancy
   - Update the relevant documentation files to reflect the correct state
   - Document the fix in your commit message

3. **Before committing**:
   - Verify documentation accuracy
   - Ensure examples in documentation work with current code
   - Check that file paths and commands are correct

This ensures that both human contributors and AI agents have accurate, up-to-date information about the project.

### Troubleshooting

If tests fail, you can inspect the cluster state:

```bash
# Check ArgoCD applications
kubectl get applications -n argocd

# Check application details
kubectl describe application <app-name> -n argocd

# Check pods
kubectl get pods -A

# View ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

### Ingress Configuration

The Kind cluster is configured **without any ingress controller** pre-installed. This is intentional as Istio (deployed via ArgoCD applications) will handle ingress functionality. The port mappings (30080, 30443) are specifically for ArgoCD access and are not related to ingress.

#### Using Kubernetes Ingress Resources

Istio supports both **VirtualServices** (Istio-native) and **Kubernetes Ingress** resources. To use standard Ingress resources:

1. **Use the `istio` IngressClass**: Set `ingressClassName: istio` in your Ingress resource
2. **Automatic TLS**: Add cert-manager annotations for automatic certificate provisioning:
   ```yaml
   annotations:
     cert-manager.io/issuer: cloudflare-dns
     cert-manager.io/issuer-kind: Issuer
   ```
3. **Example**: See `charts/shared/templates/ingress-example.yaml` for a complete example

The Istio ingress controller automatically converts Ingress resources to VirtualServices and routes traffic through the Istio Gateway, providing seamless integration with existing Kubernetes Ingress-based applications.

## Additional Documentation

- **[AGENTS.md](AGENTS.md)** - Detailed documentation for AI agents and assistants working on this project. Contains project conventions, common tasks, and troubleshooting guides.

## License

MIT
