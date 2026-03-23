# Local Development

## Nix Development Shell

The repo uses a Nix flake (`flake.nix`) with direnv (`.envrc`) to provide a reproducible development environment. When you `cd` into the repo with direnv enabled, the shell activates automatically via `use flake`.

Run `direnv allow` on first use.

### Provided tools

| Tool | Purpose |
|------|---------|
| `kubectl` | Kubernetes CLI |
| `helm` | Helm package manager |
| `kind` | Local Kubernetes clusters in Docker |
| `kubeseal` | Sealed Secrets CLI (custom wrapper, see below) |
| `gnumake` | Build automation |
| `git` | Version control |
| `bash` | Shell |
| `coreutils` | Standard UNIX utilities |
| `jq` | JSON processor |
| `curl` | HTTP client |
| `kubectx` | Cluster and namespace switching |
| `k9s` | Terminal-based Kubernetes UI |

### kubeseal wrapper

The flake provides a wrapper script around `kubeseal` that automatically passes `--controller-namespace core --controller-name sealed-secrets-operator`. You can invoke `kubeseal` as normal and these flags are prepended for you.

---

## Makefile Targets

The default cluster name is `homelab-test` (override with `CLUSTER_NAME`).

| Target | Description |
|--------|-------------|
| `make help` | Show available targets with descriptions. |
| `make setup-kind` | Create a Kind cluster with port mappings and cloud-provider-kind. |
| `make install-argocd` | Install ArgoCD via Helm into the `argocd` namespace. |
| `make insert-secrets` | Apply the `cloudflare-secret.yaml` file to the cluster. |
| `make deploy-homelab` | Deploy the homelab stack using the `charts/homelab` Helm chart. |
| `make deploy-demo` | Deploy demo applications using the `charts/demo` Helm chart. |
| `make cleanup` | Delete the Kind cluster, stop the cloud-provider-kind container, and remove `argo-password.txt`. |
| `make recreate` | Full cleanup followed by `setup-kind` and `setup-cluster` (a complete rebuild). |
| `make setup-cluster` | Run `install-argocd` then `deploy-homelab` (used by `recreate`). |

---

## Kind Cluster Setup

`scripts/setup-kind.sh` creates a single control-plane Kind cluster with four port mappings:

| Container Port | Host Port | Purpose |
|---------------|-----------|---------|
| 30080 | 30080 | ArgoCD NodePort (HTTP) |
| 30443 | 30443 | ArgoCD NodePort (HTTPS) |
| 80 | 8080 | Gateway HTTP traffic |
| 443 | 8443 | Gateway HTTPS traffic |

After the cluster is ready, the script:

1. Removes the `node.kubernetes.io/exclude-from-external-load-balancers` label from the control-plane node so LoadBalancer services can schedule there.
2. Starts a `cloud-provider-kind` Docker container (connected to the `kind` network with access to the Docker socket). This provides LoadBalancer support inside Kind, allowing services of type `LoadBalancer` to receive external IPs.

---

## Script Reference

All scripts live in `scripts/` and expect the `CLUSTER_NAME` environment variable (default: `homelab-test`).

| Script | Description |
|--------|-------------|
| `setup-kind.sh` | Creates the Kind cluster with port mappings and starts cloud-provider-kind. |
| `install-argocd.sh` | Adds the Argo Helm repo, installs ArgoCD (chart version 9.2.1) as a NodePort service on ports 30080/30443, and writes the admin password to `argo-password.txt`. |
| `deploy-homelab.sh` | Renders and applies the `charts/homelab` Helm chart to deploy the full homelab stack. |
| `deploy-core.sh` | Installs the `charts/core` Helm chart into a `core` namespace, then waits for the `cert-manager` and `istiod` ArgoCD Applications to become synced and healthy. Auto-detects the repo URL from the git remote. |
| `deploy-shared.sh` | Installs the `charts/shared` Helm chart into a `shared` namespace with the staging ACME server configured. |
| `deploy-demo.sh` | Installs the `charts/demo` Helm chart into a `demo` namespace, ensuring proper Helm ownership labels if the namespace already exists. |
| `insert-secrets.sh` | Applies `cloudflare-secret.yaml` to the cluster. |
| `cleanup.sh` | Stops and removes the cloud-provider-kind container, deletes the Kind cluster, and removes `argo-password.txt`. |
| `utils.sh` | Shared utility functions. Provides `wait-for-arg-app <app-name> [timeout] [namespace]`, which polls an ArgoCD Application until it reaches `Synced`/`Healthy` status (default timeout: 600s). |

---

## Typical Workflow

Prerequisites: Docker running, Nix installed, direnv installed.

```bash
# 1. Enter the development shell (automatic with direnv, or manually):
nix develop

# 2. Create a fresh local cluster with ArgoCD and the homelab stack:
make recreate

# 3. Access ArgoCD:
#    URL:      http://localhost:30080
#    Username: admin
#    Password: contents of argo-password.txt

# 4. Deploy demo apps (optional):
make deploy-demo

# 5. Tear everything down when done:
make cleanup
```
