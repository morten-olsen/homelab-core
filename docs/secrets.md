# Secret Management

This cluster uses four complementary approaches to manage secrets: automatic
password generation, encrypted Git secrets, cross-namespace reflection, and a
manually provisioned Cloudflare API token.

## 1. External Secrets Operator + Password Generator

Most service credentials are auto-generated at deploy time using the External
Secrets Operator `Password` generator. Each service defines a `Password`
resource (the generator) and an `ExternalSecret` that references it. The
ExternalSecret creates a standard Kubernetes `Secret` with `creationPolicy:
Owner`, meaning the secret is generated once and owned by the ExternalSecret.

All generators use `refreshInterval: "0"` or omit it (defaulting to
single-generation), so passwords are stable across reconciliation loops and are
only regenerated if the secret is deleted.

### Generated secrets

| Secret name | Chart | Template file | Length | Encoding | Notes |
|---|---|---|---|---|---|
| `volsync-restic` | shared | `backups.yaml` | 64 | default | Restic encryption password; reflected to all namespaces |
| `pihole-password` | shared | `pihole-secrets.yaml` | 32 | default | Pi-hole admin UI password |
| `pihole-dns-hmac-secret` | shared | `pihole-secrets.yaml` | 32 | default | DNS HMAC secret (key: `hmac-secret`) |
| `postgres-cluster-controller` | shared | `postgres-role-secrets.yaml` | 32 | hex | CloudNative-PG controller credentials (`kubernetes.io/basic-auth` type, username: `controller`) |
| `mariadb-root-password` | shared | `mariadb-secrets.yaml` | 32 | default | MariaDB operator root password |
| `grafana-admin` | monitor | `grafana-admin-secret.yaml` | 32 | base64 | Grafana admin credentials (username: `admin`); gated by `.Values.resources.grafanaAdminSecret.enabled` |

### How it works

Each pair follows this pattern:

```yaml
# Generator - defines password parameters
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: <name>-generator
spec:
  length: 32
  allowRepeat: false
  noUpper: false
  secretKeys:
    - password

# ExternalSecret - creates the Kubernetes Secret
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <name>
spec:
  target:
    name: <name>
    creationPolicy: Owner
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: <name>-generator
```

Some secrets (postgres-cluster-controller, grafana-admin, volsync-restic) use a
`target.template` to shape the resulting secret with fixed fields (e.g.,
username) alongside the generated password.

## 2. Sealed Secrets

The Sealed Secrets operator is deployed in the `core` chart (namespace:
`sealed-secrets`, chart version 2.18.4). It decrypts `SealedSecret` resources
in-cluster, allowing encrypted secrets to be committed to Git safely.

### kubeseal wrapper

The Nix flake (`flake.nix`) provides a wrapped `kubeseal` binary that
automatically targets the correct controller:

```nix
kubeseal-wrapped = pkgs.writeShellScriptBin "kubeseal" ''
  exec ${pkgs.kubeseal}/bin/kubeseal \
    --controller-namespace sealed-secrets \
    --controller-name sealed-secrets "$@"
'';
```

Enter the dev shell with `nix develop` and use `kubeseal` directly -- no extra
flags needed.

### Creating a sealed secret

```bash
kubectl create secret generic my-secret \
  --namespace my-ns \
  --from-literal=key=value \
  --dry-run=client -o yaml | kubeseal -o yaml > my-sealed-secret.yaml
```

## 3. Reflector

The [Reflector](https://github.com/emberstack/kubernetes-reflector) operator
(namespace: `reflector`) copies annotated secrets to other namespaces
automatically. This is used for two secrets:

### Wildcard TLS certificate

Defined in `charts/shared/templates/certificate.yaml`. A cert-manager
`Certificate` for `*.domain` is created in the `shared` namespace with these
annotations on the resulting secret:

```yaml
secretTemplate:
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "istio-ingress"
```

This copies the TLS cert to the `istio-ingress` namespace where the gateway
terminates TLS.

### Volsync restic secret

Defined in `charts/shared/templates/backups.yaml`. The `volsync-restic` secret
is annotated to reflect to all namespaces so every `ReplicationSource` can
reference it:

```yaml
annotations:
  reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
  reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
  reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: ""
```

The empty `reflection-auto-namespaces` value means all namespaces. Note: this
uses the `v1` annotation prefix (different from the TLS certificate above).

Both the ExternalSecret metadata **and** the `target.template.metadata` carry
the Reflector annotations, ensuring they survive reconciliation.

## 4. Cloudflare API Token

The Cloudflare API token is the only manually provisioned secret. It is required
for cert-manager DNS-01 challenges.

- **Template**: `charts/shared/templates/_cloudflare-secret.example.yaml` --
  documents how to create the secret via `kubectl`, base64 encoding, or
  `kubeseal`. The leading underscore prevents Helm from rendering it.
- **Live secret**: `cloudflare-secret.yaml` at the repo root, applied directly
  with `kubectl apply`. This file is in the `shared` namespace with the key
  `CLOUDFLARE_API_TOKEN`.

To set up on a new cluster:

```bash
kubectl create secret generic cloudflare-api-token \
  --namespace shared \
  --from-literal=CLOUDFLARE_API_TOKEN='your-token-here'
```

Or copy and edit `cloudflare-secret.yaml`, then apply it.

## 5. Secret Lifecycle

### First deploy

1. The `core` chart deploys all operators (External Secrets, Sealed Secrets,
   Reflector, cert-manager, Volsync).
2. External Secrets Password generators create all service passwords
   automatically when the `shared` and `monitor` charts are deployed.
3. Reflector copies the `volsync-restic` secret to all namespaces and the
   wildcard TLS cert to `istio-ingress`.
4. The Cloudflare API token must be created manually before cert-manager can
   issue certificates.

### Steady state

- Passwords are stable. Generators use `refreshInterval: "0"` so secrets are not
  rotated automatically.
- Reflector keeps reflected copies in sync if the source secret changes.
- TLS certificates are renewed automatically by cert-manager before expiry.

### Cluster rebuild

On a fresh cluster, all Password generators will create **new** passwords. This
is fine for most services (databases are recreated), but the restic backup
password must be restored from the saved copy to decrypt existing backups.

See [backups.md](backups.md) for the full disaster recovery procedure, including
how to restore the restic password before ArgoCD recreates the ExternalSecret.

Critical post-deploy actions:

1. Export and save the restic password:
   ```bash
   kubectl get secret volsync-restic -n shared \
     -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d
   ```
2. Re-apply the Cloudflare API token secret.
3. Verify TLS certificate issuance and backup schedules.
