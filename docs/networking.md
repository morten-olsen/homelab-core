# Networking

This document covers the networking stack: Istio service mesh, gateway architecture, service routing, DNS, and TLS.

## Istio Sidecar Mesh

The cluster runs Istio 1.29.1 in **sidecar mode** (the default). Istio injects an Envoy sidecar proxy into every pod in labeled namespaces, handling mTLS, L4/L7 routing, DNS interception, and observability. Sidecar injection is enabled on the `prod`, `prod-containarr`, `shared`, `monitoring`, and `demo` namespaces via the `istio-injection: enabled` label.

istiod is configured with DNS capture so the sidecar can intercept DNS queries for mesh-internal hostnames. This ensures that when a pod resolves a public domain (e.g. `ntfy.olsen.cloud`), the sidecar routes traffic directly to the in-cluster service via the `mesh` gateway on VirtualServices, avoiding internet hairpinning:

```yaml
# charts/core/values.yaml -- istiod config
meshConfig:
  ingressService: shared/istio-gateway
  ingressSelector: gateway
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_CAPTURE: "true"
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
```

- `ISTIO_META_DNS_CAPTURE` -- intercepts DNS queries before they leave the mesh.
- `ISTIO_META_DNS_AUTO_ALLOCATE` -- assigns virtual IPs for `ServiceEntry` hosts so they can be routed through the mesh.
- `ingressService: shared/istio-gateway` -- tells istiod the gateway Service lives in the `shared` namespace (not `istio-system`).

## Gateway Architecture

A single Istio gateway **Deployment** serves both public (internet-facing) and private (LAN-only) traffic on different ports. Two Istio Gateway **CRs** bind to that deployment via `selector: { istio: gateway }` and define which ports map to which traffic class.

```
                         Internet
                            |
                     [ Load Balancer ]
                            |
               +------------+------------+
               |                         |
         :18080 (HTTP)            :18443 (HTTPS)
               |                         |
               +-------+  +---------+---+
                       |  |
                 [ istio-gateway pod ]    <-- single Deployment (istio-ingress ns)
                       |  |
               +-------+  +---------+---+
               |                         |
           :80 (HTTP)              :443 (HTTPS)
               |                         |
               +------------+------------+
                            |
                        LAN only
```

### Gateway Deployment (ArgoCD Application)

Defined in `charts/shared/templates/gateway.yaml`. Deploys the upstream `istio/gateway` Helm chart into the `istio-ingress` namespace with five ports:

| Port  | Name          | Purpose              |
|-------|---------------|----------------------|
| 15021 | status-port   | Istio health checks  |
| 80    | http2         | Private HTTP         |
| 443   | https         | Private HTTPS        |
| 18080 | http-public   | Public HTTP          |
| 18443 | https-public  | Public HTTPS         |

### Gateway CRs

Both are generated from the `_gateway.yaml` partial template. Each Gateway CR configures HTTP-to-HTTPS redirect on its HTTP port and SIMPLE TLS termination on its HTTPS port using the shared wildcard cert.

**Public gateway** (`public-gateway.yaml`):
- HTTP port 18080 -- redirects to HTTPS
- HTTPS port 18443 -- terminates TLS with `wildcard-tls`

**Private gateway** (`private-gateway.yaml`):
- HTTP port 80 -- redirects to HTTPS
- HTTPS port 443 -- terminates TLS with `wildcard-tls`

Both accept all hosts (`"*"`). Access restriction (public vs. private) is handled at the load balancer / firewall level, not by Istio itself.

## VirtualService Routing

Services are exposed by creating VirtualService resources that reference either the `public` or `private` gateway (or both).

### Private-only example: Pi-hole

Pi-hole is only accessible from the LAN. Its VirtualService references the private gateway and the `mesh` gateway (for in-cluster access):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: pihole-private
spec:
  gateways:
    - shared/private       # LAN traffic through the private Gateway CR
    - mesh                 # direct pod-to-pod within the mesh
  hosts:
    - pihole.olsen.cloud
  http:
    - route:
        - destination:
            host: pihole-http
            port:
              number: 80
```

### Public + private example: Authentik

Authentik needs to be reachable from both the internet (for SSO) and the LAN. It uses two separate VirtualService resources -- one per gateway. Both include the `mesh` gateway for internal pod-to-pod routing:

```yaml
# authentik-public
spec:
  gateways: [ shared/public, mesh ]
  hosts: [ auth.olsen.cloud ]
  http:
    - route:
        - destination: { host: authentik, port: { number: 9000 } }

# authentik-private
spec:
  gateways: [ shared/private, mesh ]
  hosts: [ auth.olsen.cloud ]
  http:
    - route:
        - destination: { host: authentik, port: { number: 9000 } }
```

The split into two VirtualServices (rather than listing both gateways in one) keeps the public and private routing independently manageable.

## Mesh-Internal Routing (ServiceEntries)

When a pod calls another service by its public domain (e.g. `https://ntfy.olsen.cloud`), the sidecar's DNS proxy intercepts the query and returns a mesh-internal virtual IP (VIP) instead of the public IP. This prevents traffic from hairpinning through the internet.

This requires a `ServiceEntry` per service that declares the hostname as `MESH_INTERNAL`:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: ntfy-mesh
spec:
  hosts:
    - ntfy.olsen.cloud
  ports:
    - number: 80
      name: http
      protocol: HTTP
    - number: 443
      name: https
      protocol: HTTPS
  resolution: DNS
  location: MESH_INTERNAL
  endpoints:
    - address: gateway.istio-ingress.svc.cluster.local
      ports:
        https: 443
```

**How it works:**

- **HTTP** (port 80): The sidecar intercepts the request and routes it directly to the backend service via the VirtualService's `mesh` gateway -- no gateway hop needed.
- **HTTPS** (port 443): The sidecar passes the TLS connection through to the Istio gateway (`gateway.istio-ingress`), which terminates TLS using the wildcard cert and routes to the backend via the VirtualService.

**Important design constraints:**

- **Single ServiceEntry per hostname.** Never split HTTP and HTTPS into separate ServiceEntries for the same host -- each gets its own auto-allocated VIP, and DNS returns them randomly. If a client picks the HTTP VIP for an HTTPS request, the TLS handshake hangs.
- **DestinationRule on the gateway.** The gateway pod has no sidecar, so sidecars must not attempt mTLS when forwarding HTTPS to it. A `DestinationRule` with `tls.mode: DISABLE` on `gateway.istio-ingress.svc.cluster.local` is required (defined in `charts/shared/templates/gateway-destination-rule.yaml`).
- **All VirtualServices need the `mesh` gateway.** Without it, the sidecar has no route for mesh-internal HTTP traffic.

The common library (`apps/common`) generates ServiceEntries automatically via `common.serviceEntry` when `virtualService.enabled` is true. For services outside the common library (e.g. Authentik, Pi-hole, Grafana), ServiceEntries are defined manually in their respective templates.

## IngressClass

An Istio `IngressClass` is registered as the cluster default:

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: istio.io/ingress-controller
```

This means any `Ingress` resource without an explicit `ingressClassName` will be handled by Istio. istiod's `ingressService: shared/istio-gateway` and `ingressSelector: gateway` settings ensure those Ingress resources are served by the gateway pod in the `istio-ingress` namespace.

## DNS

### Pi-hole

Pi-hole runs as a Deployment in the `shared` namespace and provides DNS filtering for the LAN. It is backed by a 1Gi `local-path` PVC.

### dns-operator + pihole-dns sidecar

A custom **dns-operator** (chart version 0.0.3, from `morten-olsen.github.io/homelab-dns-operator`) watches a custom `DNSClass` CRD. The operator reconciles DNS record objects against whatever backend a `DNSClass` points to.

The **pihole-dns** sidecar Deployment acts as the webhook bridge between the dns-operator and Pi-hole's API. It runs alongside Pi-hole in the `shared` namespace and exposes an HTTP endpoint on port 7100.

The `DNSClass` resource ties everything together:

```yaml
apiVersion: dns.homelab.mortenolsen.pro/v1alpha1
kind: DNSClass
metadata:
  name: private-dns
spec:
  server: "http://pihole-dns-http.shared.svc.cluster.local:7100"
  defaultTTL: 300
  timeoutSeconds: 30
  hmacAuth:
    secretRef:
      name: pihole-dns-hmac-secret
      key: hmac-secret
```

When other charts create DNS record CRs referencing `private-dns`, the dns-operator calls the pihole-dns webhook, which in turn creates/updates records in Pi-hole.

## TLS

### Certificate Issuance

cert-manager uses a **Cloudflare DNS01** ACME solver to issue certificates from Let's Encrypt (production). The Issuer is defined in `charts/shared/templates/cert-issuer.yaml`:

- Issuer name: `cloudflare-dns`
- ACME server: `https://acme-v02.api.letsencrypt.org/directory`
- Solver: DNS01 via Cloudflare API token (stored in Secret `cloudflare-api-token`)
- CNAME strategy: `Follow` (supports delegated DNS validation)

cert-manager itself is configured with `--dns01-recursive-nameservers-only` and uses `8.8.8.8:53,1.1.1.1:53` to avoid resolving challenges against the local Pi-hole.

### Wildcard Certificate

A single `Certificate` resource (`charts/shared/templates/certificate.yaml`) requests a wildcard cert:

- Secret name: `wildcard-tls`
- DNS names: `*.olsen.cloud`, `olsen.cloud`, plus any additional domains (currently `*.coder.olsen.cloud`)

### Cross-namespace Reflection

The certificate lives in the `shared` namespace, but the gateway runs in `istio-ingress`. The **Reflector** operator (Emberstack) copies the secret across namespaces. The Certificate's `secretTemplate` enables this:

```yaml
secretTemplate:
  annotations:
    reflector.v1beta1.emberstack.com/reflection-allowed: "true"
    reflector.v1beta1.emberstack.com/reflection-allowed-namespaces: "istio-ingress"
```

This ensures the `wildcard-tls` secret is automatically mirrored to `istio-ingress`, where the Gateway CRs reference it as `credentialName`.
