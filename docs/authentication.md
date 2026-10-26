# Authentication

## Authentik Overview

This homelab uses [Authentik](https://goauthentik.io/) as its OIDC/OAuth2 identity provider. Authentik is deployed through a two-layer setup:

- The **authentik-operator** is deployed by the `core` chart. It is sourced from `https://mortenolsen.pro/homelab-authentik-operator` (chart: `authentik-operator`) and watches for custom resources.
- The **shared** chart creates an `AuthentikServer` CR, which the operator reconciles into a running Authentik instance.

## Architecture

The deployment is split across two Helm charts:

### Core chart (`charts/core`)

Deploys the `authentik-operator` into the `authentik` namespace. The operator defines and manages two CRDs:

- `AuthentikServer` -- represents an Authentik instance.
- `AuthentikClient` -- represents an OIDC/OAuth2 client registration.

### Shared chart (`charts/shared/templates/authentik.yaml`)

Creates three resources when `resources.authentik.enabled` is `true`:

1. **`PostgresDatabase` CR** (`authentik-db`) -- handled by the postgres-operator. This provisions a dedicated database for Authentik and populates a `authentik-db-connection` secret with connection details.
2. **`AuthentikServer` CR** (`authentik`) -- references the database connection secret and configures the Authentik instance with the desired container image and canonical hostname.
3. **Private Istio `VirtualService`** (`authentik-private`) -- routes the private and mesh gateways to the `authentik` service on port 9000. The public route was removed as approved Node2Shell containment on 2026-10-26. Login redirects and browser-side OIDC/OAuth2 flows now require LAN/VPN access, including for applications whose own routes remain public.

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

## Accessing Authentik

Authentik is exposed at:

```
https://<subdomain>.<domain>
```

With the default values (`charts/shared/values.yaml`), this resolves to `https://auth.olsen.cloud`.

The subdomain is configurable via `resources.authentik.subdomain`. Traffic is routed through the private and mesh gateways only. Internet clients cannot reach Authentik directly; establish LAN/VPN access before authenticating or enrolling a new VPN client through this identity provider. This is containment, not a replacement for patching the affected native Brotli library.

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
    image: ghcr.io/goauthentik/server:2026.2.1
    tls:
      enabled: true
      secretName: wildcard-tls
```

| Value            | Description                                           | Default                                      |
|------------------|-------------------------------------------------------|----------------------------------------------|
| `enabled`        | Toggle Authentik deployment                           | `true`                                       |
| `subdomain`      | Subdomain prefix for the Authentik UI                 | `auth`                                       |
| `image`          | Container image for the Authentik server              | `ghcr.io/goauthentik/server:2026.2.1`        |
| `tls.enabled`    | Enable TLS on the ingress                             | `true`                                       |
| `tls.secretName` | Name of the TLS secret (typically a wildcard cert)    | `wildcard-tls`                               |
