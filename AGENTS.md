# AI Agent Guidelines

This document provides context and guidelines for AI agents working with this homelab-core repository.

## Repository Structure

```
homelab-core/
├── charts/
│   ├── homelab/          # Master chart (orchestrates deployment)
│   ├── core/             # Cluster operators and controllers
│   ├── shared/           # Shared infrastructure resources
│   └── demo/             # Demo applications (can be ignored)
├── scripts/              # Deployment scripts (can be ignored)
└── .devcontainer/        # Development container configuration
```

## Key Concepts

### Chart Hierarchy

1. **homelab** - The master/orchestrator chart
   - Creates ArgoCD `Application` resources
   - Manages sync waves for deployment order
   - Located at `charts/homelab/`
   - Main values: `repoUrl`, `targetRevision`, `core.project`, `shared.project`

2. **core** - Cluster operators
   - Installs Kubernetes operators via ArgoCD Applications
   - Examples: cert-manager, Istio, Kyverno, Longhorn, etc.
   - Located at `charts/core/`
   - Uses template `_operator.yaml` to generate ArgoCD Applications
   - Configured via `values.yaml` under `operators.*`

3. **shared** - Shared infrastructure
   - Provides shared resources for applications
   - Examples: gateways, certificates, PostgreSQL cluster, Authentik, Pi-hole
   - Located at `charts/shared/`
   - Depends on operators from `core` chart

### Deployment Model

- **GitOps-based**: Uses ArgoCD for continuous deployment
- **Sync Waves**: Ensures proper deployment order
  - Wave 0: `core` chart (operators)
  - Wave 1: `shared` chart (infrastructure)
- **ArgoCD Applications**: Each operator and chart is deployed as an ArgoCD Application
- **AppProjects**: Used to organize and secure applications

### Important Files

#### `charts/homelab/values.yaml`
```yaml
repoUrl: <git-repository-url>
targetRevision: main  # Git branch, tag, or commit SHA
core:
  project: core
shared:
  project: shared
```

**Note**: The templates reference `.Values.revision`, but the values file uses `targetRevision`. You may need to add `revision: {{ .Values.targetRevision }}` to the values or update templates accordingly.

#### `charts/core/values.yaml`
- `global.project`: ArgoCD project name
- `global.syncPolicy`: ArgoCD sync policy
- `operators.*`: Configuration for each operator
  - `enabled`: Enable/disable operator
  - `version`: Helm chart version
  - `namespace`: Target namespace
  - `repoURL`: Helm repository URL
  - `chart`: Chart name (if different from operator name)
  - `values`: Helm values to pass to operator chart

#### `charts/shared/values.yaml`
- `global.domain`: Primary domain name
- `global.email`: Email for ACME certificates
- `global.acme`: ACME environment (prod/staging)
- `resources.*`: Configuration for shared resources

### Template Patterns

#### Operator Template (`charts/core/templates/_operator.yaml`)
Generates ArgoCD Applications for operators:
```yaml
{{- define "homelab-core.operator" -}}
{{- $name := first . -}}
{{- $root := last . -}}
{{- $operator := index $root.Values.operators $name -}}
{{- if $operator.enabled -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
# ... ArgoCD Application definition
{{- end }}
{{- end }}
```

#### Usage in operator templates:
```yaml
{{- range $name, $operator := .Values.operators }}
{{- include "homelab-core.operator" (list $name $) }}
{{- end }}
```

## Common Tasks

### Adding a New Operator

1. Add operator configuration to `charts/core/values.yaml`:
   ```yaml
   operators:
     new-operator:
       enabled: true
       version: 1.0.0
       namespace: new-operator
       repoURL: https://charts.example.com
       chart: new-operator
       values:
         # Operator-specific values
   ```

2. Create a template file in `charts/core/templates/`:
   ```yaml
   {{- range $name, $operator := .Values.operators }}
   {{- include "homelab-core.operator" (list $name $) }}
   {{- end }}
   ```

   Or use a specific template if needed (see `operator-cert-manager.yaml` for examples).

### Adding a Shared Resource

1. Add resource configuration to `charts/shared/values.yaml`:
   ```yaml
   resources:
     new-resource:
       enabled: true
       # Resource-specific configuration
   ```

2. Create template in `charts/shared/templates/new-resource.yaml`:
   ```yaml
   {{- if .Values.resources.newResource.enabled }}
   # Kubernetes resources
   {{- end }}
   ```

### Modifying Deployment Order

Sync waves are controlled by annotations in ArgoCD Applications:
- `argocd.argoproj.io/sync-wave: "0"` - Deploys first
- `argocd.argoproj.io/sync-wave: "1"` - Deploys second
- Higher numbers deploy later

## Important Notes for AI Agents

1. **ArgoCD Dependency**: This project REQUIRES ArgoCD to be pre-installed. The charts create ArgoCD Applications, not direct Kubernetes resources (except for the homelab chart itself).

2. **Sync Waves**: Pay attention to sync wave annotations. `core` must deploy before `shared`.

3. **Helm Values**: Most configuration happens through Helm values files, not direct template modifications.

4. **Operator Pattern**: Operators are deployed as ArgoCD Applications pointing to Helm charts, not directly installed.

5. **Namespace Management**: ArgoCD Applications create namespaces automatically via `CreateNamespace=true` sync option.

6. **GitOps Workflow**: Changes should be committed to Git. ArgoCD will sync automatically if auto-sync is enabled.

7. **Values Inheritance**: The `homelab` chart passes values to `core` and `shared` charts via ArgoCD Application helm values.

8. **Ignore Demo**: The `demo` chart and `scripts/` directory can be ignored unless specifically requested.

9. **Opinionated Design**: This is a home server setup, not production-grade. It makes specific technology choices (Istio, CloudNative-PG, etc.).

10. **Secret Management**: Uses Sealed Secrets and External Secrets Operator. Never commit unencrypted secrets.

## Common Commands

### Check ArgoCD Applications
```bash
kubectl get applications -n argocd
argocd app list
```

### View Application Details
```bash
argocd app get core
kubectl get application core -n argocd -o yaml
```

### Sync Application
```bash
argocd app sync core
```

### Template Helm Chart
```bash
helm template homelab ./charts/homelab
helm template core ./charts/core
helm template shared ./charts/shared
```

### Validate Values
```bash
helm lint ./charts/homelab
helm lint ./charts/core
helm lint ./charts/shared
```

## Troubleshooting Tips

- If ArgoCD Applications aren't syncing, check repository connectivity and permissions
- If operators fail to install, verify Helm repository URLs and chart versions
- If sync waves aren't working, check annotation values and ArgoCD version
- Certificate issues usually relate to cert-manager or DNS provider configuration
- Storage issues often relate to Longhorn configuration or node labels

## Best Practices

1. Always validate Helm charts before committing: `helm lint`
2. Test changes in a development environment first
3. Use semantic versioning for chart versions
4. Document operator-specific requirements in values.yaml comments
5. Keep sync policies consistent across applications
6. Use ServerSideApply for better conflict resolution
7. Enable auto-prune and self-heal for GitOps workflows
