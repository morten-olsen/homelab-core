# homelab-common

Helm library chart for deploying applications on the homelab platform. Provides standardized templates for Deployments, Services, VirtualServices, PVCs, OIDC, databases, secrets, backups, and monitoring probes — all driven by values.

## Install

```yaml
# Chart.yaml
apiVersion: v2
version: 1.0.0
name: my-app
dependencies:
  - name: homelab-common
    version: ">=0.1.0"
    repository: https://mortenolsen.pro/homelab-core/
```

```bash
helm dependency build
```

## Quick Start

**templates/common.yaml:**
```yaml
{{ include "common.all" (list . .Values) }}
```

**values.yaml:**
```yaml
image:
  repository: ghcr.io/org/my-app
  tag: v1.0.0

subdomain: my-app

deployment:
  strategy: Recreate
  replicas: 1

container:
  port: 8080
  healthProbe:
    type: httpGet
    path: /health

service:
  port: 80

virtualService:
  enabled: true
  gateways:
    public: true
    private: true
```

That's it. The `common.all` template renders Deployment, Service, VirtualService, ServiceEntry, Probe, and any other resources enabled in values.

## Scoped API

All entry points accept `(list <rootContext> <appValues>)`. This enables:

**Value segregation** — keep app values separate from custom config:
```yaml
# templates/common.yaml
{{ include "common.all" (list . .Values.app) }}
```
```yaml
# values.yaml
app:
  image: { repository: nginx, tag: latest }
  subdomain: myapp
  container: { port: 80 }
  service: { port: 80 }
customConfig:
  myKey: myValue
```

**Multi-app charts** — deploy multiple apps from one chart:
```yaml
{{ include "common.all" (list . .Values.frontend) }}
{{ include "common.all" (list . .Values.backend) }}
```
Use `nameOverride` in each app's values to avoid name collisions.

**Individual templates** — render specific resources:
```yaml
{{ include "common.deployment" (list . .Values) }}
{{ include "common.service" (list . .Values) }}
```

### Standalone Redis / Valkey stores

`common.standaloneStore` renders one single-replica `Recreate` Deployment and
ClusterIP Service, separately from `common.all`:

```yaml
{{ include "common.standaloneStore" (list . .Values.redis) }}
{{ include "common.standaloneStore" (list . .Values.valkey) }}
```

Each store has its own configuration; Redis and Valkey images are not
interchangeable. The helper deliberately preserves explicit selectors and
container names rather than using the application Deployment conventions.

| Store value | Meaning |
|-------------|---------|
| `name` | Deployment and Service name; supports `{release}` |
| `selectorLabels` | Immutable Deployment selector, pod labels, Service labels and selector; values support `{release}` |
| `containerName` | Container name; supports `{release}` |
| `image` | Existing `repository`, `tag` (including digest), and `pullPolicy` |
| `commonLabels` | Add application chart labels to Deployment and Service metadata only; optional |
| `portName`, `port` | Container TCP port name and number; the Service uses the same port name |
| `args` | Optional server arguments, preserved as supplied; omitted when unset |
| `resources` | Existing container resource requests and limits |
| `livenessProbe`, `readinessProbe` | Existing Kubernetes probe definitions |
| `service.type`, `service.port`, `service.targetPort` | Existing Service type and numeric ports |

The Deployment retains `revisionHistoryLimit: 0`. The helper adds no PVC,
volumes, authentication, environment variables, HTTP monitoring probes, or
server persistence arguments. These stores hold real queue state: without a
PVC, replacing a pod can lose queued work even when snapshots are enabled.
For a configuration-only migration, compare rendered Deployment selectors and
complete pod templates before rollout; do not treat this as a disposable-cache
restart or a persistence migration.

## Values Reference

### Image

```yaml
image:
  repository: ghcr.io/org/my-app
  tag: v1.0.0
  pullPolicy: IfNotPresent  # optional
```

### Deployment

```yaml
deployment:
  strategy: Recreate        # or RollingUpdate
  replicas: 1
  revisionHistoryLimit: 2   # optional, default 2
  hostNetwork: false         # optional
  dnsPolicy: ClusterFirst    # optional
  serviceAccountName: ""     # optional, supports {release} placeholder
  podAnnotations: {}         # optional
  hostAliases: []            # optional
  dns:                       # optional, custom DNS
    nameservers: ["8.8.8.8"]
    policy: None
```

### Container

```yaml
container:
  # Single port
  port: 8080

  # OR multiple ports
  ports:
    - name: http
      port: 8080
      protocol: TCP
    - name: grpc
      port: 9090
      protocol: TCP

  healthProbe:
    type: httpGet          # httpGet, tcpSocket, or exec
    path: /health          # for httpGet
    port: http             # named port or number
    initialDelaySeconds: 0 # optional
    periodSeconds: 10      # optional
    timeoutSeconds: 1      # optional
    failureThreshold: 3    # optional

  resources:               # optional
    requests: { cpu: 500m, memory: 256Mi }
    limits: { cpu: 1000m, memory: 512Mi }

  securityContext:          # optional
    privileged: false
    runAsUser: 1000
```

### Service

```yaml
service:
  # Single service
  port: 80
  type: ClusterIP

  # OR multiple services
  ports:
    - name: http
      port: 80
      targetPort: 8080
      type: ClusterIP
    - name: grpc
      port: 9090
      targetPort: 9090
      serviceName: grpc    # creates {release}-grpc service
```

### Volumes & Storage

```yaml
volumes:
  - name: data
    mountPath: /data
    persistentVolumeClaim: data     # references PVC below (prefixed with release name)
  - name: config
    mountPath: /config
    configMap: "{release}-config"   # ConfigMap reference
  - name: secrets
    mountPath: /secrets
    secret: "{release}-secrets"     # Secret reference
  - name: tmp
    mountPath: /tmp
    emptyDir: {}
  - name: host
    mountPath: /host
    hostPath: /path/on/host

persistentVolumeClaims:
  - name: data
    size: 10Gi
    storageClassName: local-path    # optional
    backup: true                    # enables VolSync backup
    backupSchedule: "0 4 * * *"    # optional, auto-generated if omitted
    backupRetain:                   # optional, uses global defaults if omitted
      daily: 7
      weekly: 4
```

### Networking (Istio)

```yaml
subdomain: my-app                  # required for VirtualService/DNS

virtualService:
  enabled: true
  gateways:
    public: true                   # internet-facing gateway
    private: true                  # LAN-only gateway
  servicePort: 80                  # optional, defaults to service port
  allowWildcard: false             # optional, adds *.subdomain.domain
  corsPolicy:                      # optional Istio HTTPCorsPolicy, set on both routes
    allowOrigins:
      - exact: "https://app.{domain}"
      - regex: "https://([a-z0-9-]+\\.)+{domain}"   # RE2, full-string match
    allowMethods: [GET, POST]
    allowHeaders: [authorization, content-type]
    maxAge: 24h
```

`corsPolicy` is rendered as written. Envoy answers preflights for matching
origins, so the app needs no CORS support of its own. Inside `regex`
matchers, `{domain}` is regex-escaped.

When `virtualService.enabled: true`, a ServiceEntry is also created for mesh-internal DNS resolution (prevents hairpinning through public DNS).

### DNS

```yaml
dns:
  enabled: true
  type: A                          # default
  dnsClassRef:
    name: private-dns              # optional
```

### Authentication (OIDC)

```yaml
oidc:
  enabled: true
  redirectUris:
    - "/api/auth/callback/authentik"
    - "/oauth/oidc/callback"
  subjectMode: user_username       # user_username, user_email, or user_id
```

Creates an AuthentikClient CR. The operator provisions a secret `{release}-oidc-credentials` with keys: `clientId`, `clientSecret`, `issuer`.

### Forward auth (Authentik in front of apps without OIDC)

```yaml
forwardAuth:
  enabled: true
  excludePaths:                    # never sent to Authentik (APIs, health)
    - /api/*
    - /ping
  accessTokenValidity: hours=8     # outpost session lifetime
  group:                           # app group members (ignored when oidc owns the group)
    members: []
  allowedGroups:
    - name: admin
      namespace: shared
  # selector: {app: my-app}        # pod labels, when not the library's own labels
  # exemptSourceNamespaces: [ns]   # callers from these namespaces skip the check
probe:
  path: /ping                      # must be an excluded path
```

Renders an `AuthentikProxyProvider` (`{release}-forward-auth`, operator 0.3.0),
the app's `AuthentikGroup` (unless `oidc.enabled` already renders it), an Istio
`CUSTOM` AuthorizationPolicy on the app's own pods, and an
`/outpost.goauthentik.io/` route in its VirtualServices for the login callback.
The policy uses the `authentik` extension provider from the core chart's mesh
config. Every request to the pods except `excludePaths` must pass Authentik,
whichever way it arrives (gateway, mesh hostname or `*.svc`). In-cluster
callers therefore need excluded paths, or their namespace listed in
`exemptSourceNamespaces` (identity comes from mesh mTLS; traffic through a
gateway carries the gateway's identity and is still checked). Charts with
their own pod labels must set `selector`, or the policy selects nothing. Access is granted by Authentik's
application bindings (the app group plus `allowedGroups`); an empty app group
grants nobody unless another group matches. Rendering fails when the
blackbox probe would hit a protected path. Excluded paths must still be
protected by the app itself (for example an API key).

### Database

```yaml
database:
  enabled: true
```

Creates a PostgresDatabase CR. The operator provisions a secret `{release}-connection` with keys: `url`, `host`, `port`, `database`, `user`, `password`.

### External Secrets

```yaml
externalSecrets:
  - name: "{release}-secrets"
    passwords:
      - name: api-key
        length: 32
        encoding: hex              # base64, base64url, base32, hex, raw
        allowRepeat: true
        secretKeys:
          - apiKey                 # key name in the generated secret
```

### Environment Variables

```yaml
env:
  # Simple value
  APP_NAME: "My App"

  # With placeholder substitution
  BASE_URL:
    value: "https://{subdomain}.{domain}"

  # From secret
  DATABASE_URL:
    valueFrom:
      secretKeyRef:
        name: "{release}-connection"
        key: url

  # From ConfigMap
  CONFIG_VALUE:
    valueFrom:
      configMapKeyRef:
        name: "{release}-config"
        key: value
```

A `TZ` env var is automatically added from `globals.timezone`.

### Init Containers

```yaml
initContainers:
  - name: fix-permissions
    image: busybox
    command: ["sh", "-c", "chown -R 1000:1000 /data"]
    volumeMounts:
      - name: data
        mountPath: /data
    securityContext:
      runAsUser: 0
```

Placeholders (`{release}`, `{domain}`, etc.) are supported in init container specs.

### Command & Args

```yaml
command:
  - /bin/sh
  - -c
args:
  - |
    echo "Starting..."
    exec /app/start.sh
```

Placeholders are supported in command and args.

## Placeholders

Dynamic values resolved at template time:

| Placeholder | Resolves to | Example |
|-------------|-------------|---------|
| `{release}` | `.Release.Name` | `my-app` |
| `{namespace}` | `.Release.Namespace` | `prod` |
| `{fullname}` | `common.fullname` | `my-app` |
| `{subdomain}` | `.Values.subdomain` | `myapp` |
| `{domain}` | `.Values.globals.domain` | `example.com` |
| `{timezone}` | `.Values.globals.timezone` | `Europe/Amsterdam` |

Supported in: `env`, `command`, `args`, `initContainers`, volume references (`configMap`, `secret`), `serviceAccountName`, `virtualService.corsPolicy.allowOrigins`.

## Blackbox Probe

A Service gets an HTTP blackbox Probe by default. The default module requires a
2xx response from `/`. Override the health path or module when that is not the
application's contract:

```yaml
probe:
  path: /api/health
  module: http_2xx       # optional; defaults to http_2xx
```

Modules are defined by the platform blackbox-exporter configuration. Select a
non-default module deliberately; do not broaden the global `http_2xx` contract to
hide one application's false positive. Set `probe.enabled: false` only when no
meaningful service-level probe is possible.

## Entry Points

All accept `(list <rootContext> <appValues>)`.

| Template | Resource | Rendered when |
|----------|----------|---------------|
| `common.all` | Everything below | Always |
| `common.deployment` | Deployment | `deployment` defined |
| `common.service` | Service(s) | `service` defined |
| `common.serviceAccount` | ServiceAccount | `serviceAccount` defined |
| `common.pvc` | PersistentVolumeClaim(s) | `persistentVolumeClaims` defined |
| `common.virtualService` | VirtualService(s) | `virtualService.enabled` |
| `common.serviceEntry` | ServiceEntry | `virtualService.enabled` |
| `common.dns` | DNSRecord | `dns.enabled` |
| `common.oidc` | AuthentikClient | `oidc.enabled` |
| `common.database` | PostgresDatabase | `database.enabled` |
| `common.externalSecrets` | Password + ExternalSecret | `externalSecrets` defined |
| `common.probe` | Blackbox Probe | `service` defined (auto) |
| `common.backup` | VolSync ReplicationSource | PVC with `backup: true` |

## Helpers

For use in custom templates (receive the standard Helm context, not the scoped list):

| Helper | Returns |
|--------|---------|
| `common.fullname` | Release-qualified app name |
| `common.name` | Chart name |
| `common.labels` | Standard Kubernetes labels |
| `common.selectorLabels` | Pod selector labels |
| `common.domain` | `subdomain.globals.domain` |
| `common.url` | `https://subdomain.globals.domain` |
| `common.containerPort` | Primary container port |
| `common.servicePort` | Primary service port |
| `common.healthProbe` | Probe spec |
| `common.volumeMounts` | Volume mount specs |
| `common.volumes` | Volume specs |
| `common.env` | Environment variable specs |

## Secret Reference

| Feature | Secret name | Keys |
|---------|-------------|------|
| OIDC | `{release}-oidc-credentials` | `clientId`, `clientSecret`, `issuer` |
| Database | `{release}-connection` | `url`, `host`, `port`, `database`, `user`, `password` |
| External Secrets | configurable | configurable via `secretKeys` |

## GitOps application access (0.2.0)

OIDC creates an `AuthentikGroup` with the same namespace and name as the
`AuthentikClient`. The group resource is the only owner of its complete direct
membership. Grant app access through `oidc.group.members`; add existing central
`AuthentikGroup` references through `oidc.allowedGroups`. Additional grants always
extend the application's own group, including when explicitly set to `[]`.

```yaml
oidc:
  enabled: true
  redirectUris: [/callback]
  group:
    members:
      - id: 123
        uuid: 11111111-2222-4333-8444-555555555555
  allowedGroups:
    - name: admin
      namespace: shared
```

User references pin existing Authentik IDs and UUIDs; the operator never creates
users or superuser privileges. The backing group name is
`gitops/<namespace>/<resource-name>`, preventing accidental adoption of an
existing group named `admin`. Define central groups in
`resources.authentik.groups` in the shared chart. Never create a second group
resource to control a chart-generated group's membership.

Requires Authentik operator 0.2.0 and its CRDs **before** updating consumers.
Missing/unready groups close managed applications. An empty app group grants
nobody access unless an additional group matches. For an inventoried legacy
application binding that must be replaced, set its UUID in
`oidc.replacesBindings`; an unapproved binding blocks cutover with access closed.
Custom clients can call `common.oidcGroup` and `common.allowedGroups` using the
same scoped values. `common.oidcGroup` is unconditional; callers decide whether
their custom OIDC enrollment is enabled.

Run `charts/homelab-common/tests/render.sh` for the library's rendering tests.
