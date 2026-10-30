# Authentication

## Authentik Overview

This homelab uses [Authentik](https://goauthentik.io/) as its OIDC/OAuth2 identity provider. Authentik is deployed through a two-layer setup:

- The **authentik-operator** is deployed by the `core` chart. It is sourced from `https://mortenolsen.pro/homelab-authentik-operator` (chart: `authentik-operator`) and watches for custom resources.
- The **shared** chart creates an `AuthentikServer` CR, which the operator reconciles into a running Authentik instance.

## Architecture

The deployment is split across two Helm charts:

### Core chart (`charts/core`)

Deploys the `authentik-operator` into the `authentik` namespace. The operator defines and manages four CRDs:

- `AuthentikServer` -- represents an Authentik instance.
- `AuthentikClient` -- represents an OIDC/OAuth2 client registration.
- `AuthentikGroup` -- owns a GitOps access group and its complete membership list.
- `AuthentikProxyProvider` -- a forward-auth proxy provider served by the embedded outpost (operator 0.3.0).

### Shared chart (`charts/shared/templates/authentik.yaml`)

Creates the following resources when `resources.authentik.enabled` is `true`:

1. **`PostgresDatabase` CR** (`authentik-db`) -- handled by the postgres-operator. This provisions a dedicated database for Authentik and populates a `authentik-db-connection` secret with connection details.
2. **`AuthentikServer` CR** (`authentik`) -- references the database connection secret and configures the Authentik instance with the desired container image and canonical hostname.
3. **Private Istio `VirtualService`** (`authentik-private`) -- routes the private and mesh gateways to the `authentik` service on port 9000.
4. **Public bootstrap `VirtualService`** (`authentik-public`) -- preserves external IdP login/OIDC access so a new NetBird client can authenticate before joining the private network. The public prefixes `/if/admin`, `/administration`, `/api/v3/admin` and `/-/impersonation` retain their former 403 denials; these are path restrictions, not a claim of complete privileged-API isolation.
5. **PersistentVolumeClaim** (`authentik-data`) -- created when `resources.authentik.storage.enabled` is `true`; referenced by `AuthentikServer.spec.dataVolumeClaimName` for shared local file storage.

The separate `charts/shared/templates/authentik-groups.yaml` template creates the
configured `AuthentikGroup` resources, initially `shared/admin`, when Authentik is
enabled.

## Database Integration

Authentik gets its own Postgres database via the custom `PostgresDatabase` CRD (API group `postgres.homelab.mortenolsen.pro/v1`). The postgres-operator watches for these CRs, creates the database inside the shared Postgres cluster, and writes connection credentials into a Kubernetes secret.

The secret `authentik-db-connection` contains four keys:

| Key        | Description                        |
|------------|------------------------------------|
| `host`     | Postgres host address              |
| `user`     | Database user                      |
| `database` | Database name                      |
| `password` | Database password                  |

The `AuthentikServer` spec references each of these keys individually via `postgresHostSecretRef`, `postgresUserSecretRef`, `postgresDatabaseSecretRef`, and `postgresPasswordSecretRef`.

## Uploaded files and persistence

By default, `resources.authentik.storage` provisions a `1Gi`, `ReadWriteOnce`
`local-path` claim named `authentik-data` in the AuthentikServer namespace.
The operator mounts this same claim as volume `data` at `/data` in both the
server and worker. A real `/data` mount is required for Authentik's local file
backend to allow uploads, including flow background images; database storage
alone does not enable or persist these files. The volume must be writable by
Authentik's UID/GID `1000`.

This configuration targets the single-node K3s cluster: `ReadWriteOnce` permits
the server and worker to share the claim on that node, but `local-path` data is
node-local and does not provide replication or protection against node loss.
Uploads survive pod replacement while the underlying volume remains available.
Disabling `resources.authentik.storage.enabled` omits both the claim manifest and
the server's claim reference; Authentik then has no persistent local upload
storage. Disabling Authentik omits both resources as well.

The PVC carries Helm `keep` and ArgoCD `Prune=false,Delete=false` annotations to
avoid automatic deletion. These retention safeguards are **not backups**.
No automatic backup of `/data` is configured by this storage change. Authentik
recovery requires both its PostgreSQL database and a separately arranged backup
of this volume's files; database backups alone do not contain uploaded images.
The shared chart manages the claim; the operator only references an existing
claim and does not create, own or delete it.

## Accessing Authentik

Authentik is exposed at:

```
https://<subdomain>.<domain>
```

With the default values (`charts/shared/values.yaml`), this resolves to `https://auth.olsen.cloud`.

The subdomain is configurable via `resources.authentik.subdomain`. Authentik is a public bootstrap exception alongside NetBird client/control and Pages (`mortenolsen.pro` and its wildcard); ordinary application routes remain private. Do not require NetBird connectivity or proxy SSO to reach the IdP that issues the initial NetBird login. This approved routing exception does not patch Authentik's known native Brotli package finding; runtime remediation remains tracked separately in Mission Control.

## Creating OIDC Clients

To register an application with Authentik, create an `AuthentikClient` CR. The demo chart provides an example at `charts/demo/templates/authentik-client.yaml`:

```yaml
apiVersion: authentik.homelab.mortenolsen.pro/v1alpha1
kind: AuthentikClient
metadata:
  name: "autentik-client"
  namespace: "{{ .Release.Namespace }}"
spec:
  serverRef:
    name: authentik
    namespace: shared
  name: Demo application
  redirectUris:
    - https://myapp.example.com/callback
    - https://myapp.example.com/auth/callback
```

Key fields:

- `serverRef` -- points to the `AuthentikServer` instance (typically `authentik` in the `shared` namespace).
- `name` -- human-readable application name shown in the Authentik UI.
- `redirectUris` -- list of allowed OAuth2 redirect URIs for the client.

The operator reconciles this CR into an Authentik OAuth2 provider and application. Client credentials (client ID and secret) are made available as Kubernetes secrets.

## Configuration Reference

All Authentik settings live under `resources.authentik` in `charts/shared/values.yaml`:

```yaml
resources:
  authentik:
    enabled: true
    subdomain: auth
    image: ghcr.io/goauthentik/server:2026.8.5
    storage:
      enabled: true
      size: 1Gi
      storageClassName: local-path
    tls:
      enabled: true
      secretName: wildcard-tls
```

| Value            | Description                                           | Default                                      |
|------------------|-------------------------------------------------------|----------------------------------------------|
| `enabled`        | Toggle Authentik deployment                           | `true`                                       |
| `subdomain`      | Subdomain prefix for the Authentik UI                 | `auth`                                       |
| `image`          | Container image for the Authentik server              | `ghcr.io/goauthentik/server:2026.8.5`        |
| `storage.enabled` | Create and mount the shared local upload claim       | `true`                                       |
| `storage.size`   | Requested capacity for `authentik-data`               | `1Gi`                                        |
| `storage.storageClassName` | Storage class for the upload claim         | `local-path`                                 |
| `tls.enabled`    | Enable TLS on the ingress                             | `true`                                       |
| `tls.secretName` | Name of the TLS secret (typically a wildcard cert)    | `wildcard-tls`                               |

### Image updates and decoder security

The configured official image is `2026.8.5`. The upgrade from `2026.8.3` was
preflighted by comparing all 659 upstream database migration files: no migration
files were added, removed or changed.

This application update is **not a Node2Shell / CVE-2026-111497 remediation**.
The inspected official image still packages Debian `libbrotli1=1.1.0-2+b7`;
the maintained Debian fix is `1.1.0-2+deb13u1`. Component presence does not prove
that Authentik exposes the vulnerable decoder, and no vendor-backed
non-applicability determination has been established. HOMEIT-445 remains open;
HOMEIT-451 tracks this application update and public-bootstrap verification.

The existing public login exception for NetBird bootstrap is unchanged. Keep
the public admin/impersonation prefix denials and the private route in place;
do not automatically expose additional applications after an image update.

## GitOps groups and application access

Authentik operator 0.2.0 adds namespaced `AuthentikGroup` resources and
`AuthentikClient.allowedGroups`. The common library 0.2.0 creates an application
group and always includes it in the client's allowed groups. Additional
`oidc.allowedGroups` references extend it. Put the complete app membership list
in `oidc.group.members`; there is no second membership resource or UI-owned list.

Central groups are declared under `resources.authentik.groups` in the shared
chart. `shared/admin` initially contains the existing `morten` user pinned by
numeric ID and immutable UUID. Its backing group is `gitops/shared/admin`, with
`is_superuser=false`, no roles and no parent groups. This group controls access
to applications only. The pre-existing Authentik groups named `admin` and
`authentik Admins` remain unmanaged and unchanged. Application administrator
privileges remain each application's own configuration.

Managed backing groups carry the originating Kubernetes UID. Same-name groups
without that marker are conflicts, including after a CR is deleted/recreated.
Users are referenced by ID and UUID, not mutable names or email addresses. No
users, invitations, passwords or superuser privileges are provisioned. UI edits
to managed membership/privilege fields are drift. Deleting a managed group
revokes its direct membership and retains its Authentik identity; it never
implicitly deletes pre-existing identity data. An undeclared child group closes
referencing applications until the hierarchy conflict is resolved.

New clients require resolved allowed groups before provider attachment. Migrating
clients replaces only an inventoried binding set, under a constant-false guard
and ALL mode, then verifies exact ANY group bindings. Empty/missing groups and
partial failures close managed applications. Legacy clients without an explicit
list retain their previous access solely during staged migration; once managed,
omitting or emptying the list denies access. A failed/unreachable API cannot
promise immediate revocation: inspect live bindings/provider attachment and
conditions. Group changes trigger referencing clients; periodic reconciliation
repairs drift. Existing app sessions and issued tokens have separate lifetimes.

Merge order: publish approved operator 0.2.0, merge this core upgrade and establish
`shared/admin`, then migrate application chart dependencies and grants in agreed
stages with new authorization attempts per application. Publishing core also
publishes common 0.2.0, core 0.1.10 and shared 0.1.28 through the existing Pages
workflow; obtain release approval before that merge. See HOMEIT-474 and the base
runbook `docs/authentik-group-cutover.md` for the inventory and verification plan.

## Forward auth for applications without OIDC

Operator 0.3.0 adds `AuthentikProxyProvider` (see the operator's ADR 0002) and
the core chart registers an Istio extension provider named `authentik` in the
istiod mesh config. It sends ext_authz checks to the embedded outpost at
`authentik.shared.svc.cluster.local:9000/outpost.goauthentik.io/auth/envoy`. The
provider does nothing until a `CUSTOM` AuthorizationPolicy names it.

Applications opt in through `forwardAuth` in homelab-common 0.3.0, which renders
the proxy provider, the app's access group, a `CUSTOM` policy on the app's own
pods and the `/outpost.goauthentik.io/` callback route. Group restriction is
enforced by Authentik's application bindings, exactly as for OIDC clients;
Istio never inspects claims. Paths listed in `forwardAuth.excludePaths` skip the
check entirely, so API-key-protected APIs keep working without a session and
without depending on Authentik. If Authentik is down, protected UIs fail closed.

The operator attaches only its own providers to the shared embedded outpost and
sets the outpost's `authentik_host` to `https://auth.olsen.cloud`. Removing a user
from a group blocks new logins; live outpost sessions last until
`accessTokenValidity` (default `hours=8`). Roll back an application by disabling
`forwardAuth`; the policy, route and provider are removed together.

## Platform logins: ArgoCD, Grafana and kubectl

With the `auth` feature on, ArgoCD, Grafana and kubectl log in through Authentik and admit
only `shared/admin` (backing group `gitops/shared/admin`). Each client lists that
group as its only allowed group; there is no per-app group. The built-in admin
accounts stay enabled as breakglass for when Authentik or the cluster is
unhealthy.

| UI | Client (namespace/name, slug) | Config |
|---|---|---|
| ArgoCD | `argocd/argocd`, `argocd-argocd`; public, PKCE | shared `resources.authentik.argocdClient`; core `argocdSso` sets `url`, `oidc.config` and `g, gitops/shared/admin, role:admin` |
| Grafana | `monitoring/grafana`, `monitoring-grafana`; confidential | monitor `grafanaSso` renders the client and `auth.generic_oauth`; the group maps to `Admin`, `role_attribute_strict` refuses anyone else |
| kubectl | `shared/kubernetes`, `shared-kubernetes`; public, PKCE, `offline_access` | shared `resources.authentik.kubernetesClient` renders the client and ClusterRoleBinding `oidc-shared-admin` (`oidc:gitops/shared/admin` → `cluster-admin`); the API server's AuthenticationConfiguration is host configuration, documented in the base repository |

Both clients sign with `authentik Self-signed Certificate`, so tokens can be
verified against the provider JWKS (ArgoCD requires that; HS256 tokens signed
with the client secret are not). ArgoCD's client is public because ArgoCD reads
a referenced client secret only from Secrets labelled `app.kubernetes.io/part-of:
argocd`, which the operator does not set; ArgoCD exchanges the code with PKCE
instead. `argocd login <host> --sso` uses the same client through
`http://localhost:8085/auth/callback`.

kubelogin refreshes the 1h ID token with the refresh token (30 days, renewed on
every refresh). Authentik does not re-check the application's group binding on
refresh, but it rebuilds the `groups` claim from current membership, and the API
server requires the group in every token. Removing someone from `shared/admin`
therefore ends their cluster access within an hour. Client certificates do not
depend on Authentik and remain the breakglass.

The homelab chart enables these with `features.auth` (ArgoCD also needs
`features.gitops`) and passes `platform.domain` to the core chart as
`global.domain`. Group membership changes stop new logins only; existing ArgoCD
and Grafana sessions keep their own lifetimes.
