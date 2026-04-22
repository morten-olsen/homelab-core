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
```

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

Supported in: `env`, `command`, `args`, `initContainers`, volume references (`configMap`, `secret`), `serviceAccountName`.

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
