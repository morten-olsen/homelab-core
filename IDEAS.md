# Homelab Platform Ideas

A living document of improvements and features for building a full-featured, single-node homelab platform. The guiding philosophy: **capable when you need it, hands-off when you don't.** No DevOps team required.

---

## Table of Contents

1. [Automatic Maintenance](#1-automatic-maintenance)
2. [Backup & Disaster Recovery](#2-backup--disaster-recovery)
3. [Storage](#3-storage)
4. [Networking & Remote Access](#4-networking--remote-access)
5. [Observability](#5-observability)
6. [Security](#6-security)
7. [Identity & Access Management](#7-identity--access-management)
8. [Developer Platform](#8-developer-platform)
9. [Home Automation](#9-home-automation)
10. [Media & Files](#10-media--files)
11. [AI & Local Intelligence](#11-ai--local-intelligence)
12. [Notifications & Alerting](#12-notifications--alerting)
13. [Database Management](#13-database-management)
14. [Resource Management](#14-resource-management)
15. [Platform UX](#15-platform-ux)

---

## 1. Automatic Maintenance

**Goal:** The cluster should keep itself up to date with minimal intervention.

### Renovate Bot (High Priority)
Deploy [Renovate](https://docs.renovatebot.com/) as a self-hosted instance (or use the GitHub App) to automatically open PRs when Helm chart versions or container image tags change. Configured with auto-merge for patch/minor updates on non-critical components, and human review required for major bumps.

- Renovate reads `Chart.yaml` and `values.yaml` files natively
- Group related updates (e.g. all kube-prometheus-stack components) into a single PR
- Schedule updates to run during off-hours to avoid disruption

### Automatic ArgoCD Self-Update
Configure ArgoCD's own Application to track its chart with a semver constraint and auto-sync. ArgoCD can update itself safely.

### OS / Node Maintenance
For the underlying host (if running k3s or similar):
- **kured** — automatic node reboots when the OS signals a restart is needed (e.g. after a kernel update), with proper cordon/drain via the Kubernetes API so workloads restart cleanly before rebooting
- Pair with unattended-upgrades (Debian/Ubuntu) or dnf-automatic (Fedora/RHEL) on the host for OS package updates

### CRD Version Tracking
Add a Kyverno policy or ArgoCD notification that warns when installed CRDs are lagging behind their operator's supported versions — a common silent breakage point.

---

## 2. Backup & Disaster Recovery

**Goal:** Survive hardware failure, accidental deletion, or a botched upgrade without losing data or spending a weekend rebuilding.

### Velero (Cluster State Backup)
[Velero](https://velero.io/) backs up Kubernetes resources and persistent volume snapshots on a schedule. For a homelab, a daily backup retained for 7–14 days is sufficient.

- Store backups in Backblaze B2 or any S3-compatible object store (cheap offsite storage)
- Include namespace-level backups for easy selective restore
- Test restores periodically — a backup you've never restored is just a hope

### CloudNative-PG Scheduled Backups
CloudNative-PG has first-class support for WAL archiving and base backups to S3. Enable:
- Continuous WAL archiving to object storage (point-in-time recovery)
- Daily base backups
- Retain 7 days minimum

This is separate from Velero and gives fine-grained PITR for the PostgreSQL cluster.

### Persistent Volume Snapshot Class
Define a `VolumeSnapshotClass` backed by the local storage driver so that Velero can take consistent PV snapshots. On a single node this is straightforward with CSI-compliant storage (see Storage section).

### Backup Monitoring
Add a Prometheus alert (via AlertManager) that fires if a Velero backup job hasn't succeeded within the last 25 hours. Silent backup failures are the worst kind.

### Runbook / Recovery Playbook
A `RECOVERY.md` document describing step-by-step how to bootstrap the cluster from zero and restore from backup. Write it before you need it.

---

## 3. Storage

**Goal:** Better visibility into disk usage, support for volume snapshots, and optional network-attached storage for shared data.

### Replace Local-Path with a CSI-Compliant Driver
The current local-path provisioner works but lacks:
- Volume snapshot support (needed for Velero)
- Volume expansion
- Usage metrics exposed to Prometheus

**Options:**
- **TopoLVM** — LVM-backed CSI driver, thin provisioning, snapshots, metrics. Good fit for a single node with dedicated disk(s) for the cluster.
- **OpenEBS Hostpath** — drop-in replacement for local-path with snapshot support and a cleaner CRD model.

Longhorn is often recommended but adds significant overhead (multiple pods per volume) that isn't worth it on a single node.

### Storage Capacity Planning Dashboard
A Grafana dashboard showing:
- PV usage per volume
- Node disk pressure trends
- Projected time to full (based on growth rate)

The kube-prometheus-stack already scrapes kubelet storage metrics — this is a dashboard configuration task.

### NFS or SMB Integration (Optional)
For media files, shared documents, or data that needs to be accessible both inside and outside the cluster:
- Mount a NAS share (NFS/SMB) on the node and expose it via a Kubernetes StorageClass using `nfs-subdir-external-provisioner` or a static PV
- This separates "cluster storage" from "bulk/media storage" cleanly

---

## 4. Networking & Remote Access

**Goal:** Secure access to the homelab from anywhere, without exposing ports directly to the internet.

### Tailscale (High Priority)
Deploy [Tailscale](https://tailscale.com/) (operator or sidecar model) for zero-config VPN access to cluster services. The Tailscale Kubernetes operator can:
- Expose specific Services via a Tailscale IP (no port forwarding required)
- Act as a subnet router for the cluster's pod/service CIDR
- Integrate with Tailscale ACLs for per-device access control

This is a better model than punching holes in a firewall for a homelab.

### Cloudflare Tunnel (Alternative/Complement)
For services that need to be publicly accessible (e.g. a personal website, webhook endpoints):
- Run `cloudflared` as a Deployment, routing specific hostnames through a Cloudflare Tunnel
- No inbound firewall ports needed
- TLS handled by Cloudflare

Can coexist with Tailscale: private services via Tailscale, public services via Cloudflare Tunnel.

### External DNS Operator
[external-dns](https://github.com/kubernetes-sigs/external-dns) watches Kubernetes Services and Ingresses and automatically creates/updates DNS records in Cloudflare (already used for cert-manager). This removes the need to manually manage DNS records when adding new services.

Configure with:
- `cloudflare` provider (reuse existing Cloudflare API token)
- Annotation-driven: only manage records for resources with `external-dns.alpha.kubernetes.io/hostname` annotation
- Internal domain (`*.olsen.cloud`) via Pi-hole custom DNS or ExternalDNS pointing at local IPs

### MetalLB or Cilium L2 Announcements
If running on bare metal (not Kind), replace cloud-provider-kind with [MetalLB](https://metallb.universe.tf/) in L2 mode or Cilium's L2 announcement feature. Assign a pool of IPs from your LAN to LoadBalancer Services — cleaner than NodePort for permanent deployments.

---

## 5. Observability

**Goal:** Know what's happening in the cluster without having to SSH in and guess. The monitoring stack exists — make it actually useful.

### Loki (Log Aggregation)
Add [Loki](https://grafana.com/oss/loki/) to the monitoring chart, deployed alongside Grafana. Use [Alloy](https://grafana.com/docs/alloy/) (Grafana's OpenTelemetry-native agent, successor to Promtail) to ship pod logs.

- Single-node Loki with filesystem backend is simple and low-resource
- Enables log correlation with metrics in Grafana (jump from a graph spike to the logs from that time range)
- Retention: 7–14 days is plenty for a homelab

### Distributed Tracing with Tempo
Add [Grafana Tempo](https://grafana.com/oss/tempo/) for trace storage. Istio (already in the stack) can emit trace data via OpenTelemetry. Useful for debugging latency in multi-service applications.

Low resource in "single binary" mode. Pairs with Loki and Prometheus for the full Grafana observability stack.

### Curated Grafana Dashboards
Pre-configure dashboards in the monitoring chart values:
- Kubernetes cluster overview (already available via kube-prometheus-stack)
- ArgoCD sync status and health
- Istio service mesh traffic (official Istio dashboards)
- PostgreSQL (CloudNative-PG ships Prometheus metrics)
- Pi-hole (gravity list, blocked queries over time)
- Node disk, CPU, memory trends with predictive alerts

All of these can be imported via Grafana dashboard ConfigMaps (already supported by the kube-prometheus-stack chart).

### SLO / Uptime Tracking
Add [Pyrra](https://github.com/pyrra-dev/pyrra) or configure Prometheus recording rules for simple SLOs on key services (e.g. "Authentik should be available 99.9% of the time"). Gives a meaningful signal beyond raw uptime.

### Synthetic Monitoring
Deploy [Blackbox Exporter](https://github.com/prometheus/blackbox_exporter) to probe HTTP endpoints, DNS resolution, and TLS certificate validity from within the cluster. Alert if cert expiry < 14 days or if a service fails its health probe.

---

## 6. Security

**Goal:** Reasonable security posture without security theater. Single node homelab, not a bank — but also not a free-for-all.

### Enable Falco
Falco is already in the chart but disabled. Enable it with a curated ruleset:
- Alert on unexpected privilege escalation
- Alert on sensitive file access from unexpected processes
- Route Falco alerts to Alertmanager/Grafana

Start with the default rules; tune out noise over time.

### CrowdSec
[CrowdSec](https://www.crowdsec.net/) is a collaborative threat intelligence system that analyzes logs (Nginx, SSH, application logs) and blocks IPs that are actively attacking other CrowdSec users worldwide. Has a Kubernetes operator and integrates with Istio/ingress.

Complements Falco: Falco watches inside the cluster, CrowdSec watches the edge.

### Network Policies (Kyverno + Istio)
Use Kyverno to enforce a default-deny network policy on all new namespaces, requiring explicit allow rules. Istio's AuthorizationPolicy can enforce this at the service mesh level.

Add a Kyverno ClusterPolicy that generates a default `NetworkPolicy` and Istio `PeerAuthentication` (mTLS mode: STRICT) in every new namespace automatically.

### Regular Security Scans
Trivy Operator is already installed. Configure it to:
- Scan all running images on a schedule
- Generate `VulnerabilityReport` CRs
- Alert (via Prometheus metrics + AlertManager) if a HIGH or CRITICAL CVE is found in a running container

Add a Grafana dashboard for Trivy scan results.

### Secrets Hygiene
- Audit and remove any plaintext secrets from values files (even in private repos, secrets in Git is a bad habit)
- Standardize on either Sealed Secrets or External Secrets (both in the stack currently) — pick one primary approach for clarity
- Add a pre-commit hook (using `detect-secrets` or `gitleaks`) to prevent accidental secret commits

---

## 7. Identity & Access Management

**Goal:** Single sign-on for everything. Log in once, access all services.

### Authentik as the Central IdP
Authentik is already deployed. Expand its use:
- Configure OIDC/OAuth2 providers for every service that supports it (Grafana, ArgoCD, code-server, Gitea, etc.)
- Use Authentik's proxy provider + outpost for services that don't have native SSO (add auth without touching the app)
- Define groups: `homelab-admins`, `homelab-users`, `homelab-readonly`

### Authentik Blueprints (GitOps for Auth Config)
Authentik supports [Blueprints](https://docs.goauthentik.io/docs/customize/blueprints/) — YAML files that declaratively configure flows, providers, and applications. Store blueprints in this repo and mount them via ConfigMap. This makes the auth configuration reproducible and version-controlled.

### ArgoCD OIDC Integration
Configure ArgoCD to authenticate via Authentik (OIDC). Map Authentik groups to ArgoCD RBAC roles. Removes the need for ArgoCD-local user management.

### Service Account / API Token Management
Use Authentik's token management or a dedicated secret store (Vault Lite: [OpenBao](https://openbao.org/)) for API tokens, webhook secrets, and application credentials. Audit tokens periodically.

---

## 8. Developer Platform

**Goal:** A self-hosted developer environment that rivals cloud platforms for personal projects.

### Gitea / Forgejo (Self-Hosted Git)
Deploy [Forgejo](https://forgejo.org/) (community fork of Gitea) for self-hosted Git repositories:
- Mirror GitHub repos locally for offline access
- Private repos for personal projects
- Webhook integration with the CI system
- Uses the existing CloudNative-PG PostgreSQL cluster for its database

### Woodpecker CI
[Woodpecker CI](https://woodpecker-ci.org/) is a lightweight CI system (Drone-compatible) that runs pipelines as Kubernetes Jobs:
- Integrates natively with Gitea/Forgejo
- Pipelines defined in `.woodpecker.yml` per repo
- No separate agent infrastructure needed on a single node

Alternative: **Tekton** for a more Kubernetes-native approach, but Woodpecker is far simpler to operate.

### Harbor (Container Registry)
[Harbor](https://goharbor.io/) is a self-hosted OCI registry with:
- Vulnerability scanning (integrates with Trivy, already in the stack)
- Image replication from Docker Hub (proxy cache to avoid pull rate limits)
- OIDC auth via Authentik
- Notary for image signing

Caching Docker Hub images through Harbor reduces external dependency and speeds up deployments.

### Coder (Cloud Development Environments)
The domain `*.coder.olsen.cloud` is already referenced in the repo. [Coder](https://coder.com/) spins up development environments as Kubernetes pods:
- Browser-based VS Code (code-server) or SSH access
- Workspace templates defined as Terraform/Helm
- Environments start on demand, stop when idle (saves resources)
- SSO via Authentik

### Backstage (Internal Developer Portal) — Optional / Advanced
[Backstage](https://backstage.io/) is a developer portal that catalogs all services, documentation, and infrastructure. Useful if the homelab grows to 10+ services and you want a single place to find everything. Heavier to operate; consider after the basics are solid.

---

## 9. Home Automation

**Goal:** Run home automation in the cluster rather than on a separate Raspberry Pi, keeping everything in one managed place.

### Home Assistant
Deploy [Home Assistant](https://www.home-assistant.io/) as a Kubernetes pod:
- Use the `homeassistant/home-assistant` container
- Host networking or specific device passthrough for Zigbee/Z-Wave USB sticks (requires node affinity to pin to the physical node)
- Persistent storage for configuration and database
- Expose via Istio + Authentik forward-auth

### Mosquitto (MQTT Broker)
[Eclipse Mosquitto](https://mosquitto.org/) as a lightweight MQTT broker for IoT device communication:
- Used by Home Assistant, Zigbee2MQTT, ESPHome, etc.
- Simple StatefulSet with a 1Gi PV for persistence
- TLS via cert-manager

### Zigbee2MQTT
[Zigbee2MQTT](https://www.zigbee2mqtt.io/) bridges Zigbee devices to MQTT without a proprietary hub:
- Requires access to a Zigbee USB coordinator (e.g. Sonoff Zigbee 3.0 USB Dongle)
- Node affinity + USB device passthrough via hostPath
- Exposes all Zigbee devices as MQTT topics, discoverable by Home Assistant

### ESPHome
[ESPHome](https://esphome.io/) for managing ESP8266/ESP32 microcontroller firmware:
- Web-based dashboard for flashing and monitoring devices
- Integrates with Home Assistant natively

### Node-RED — Optional
[Node-RED](https://nodered.org/) for visual automation flows, useful for complex logic that Home Assistant's automation YAML becomes unwieldy for.

---

## 10. Media & Files

**Goal:** Self-hosted media streaming and file storage accessible on the LAN (and optionally remotely via Tailscale).

### Jellyfin
[Jellyfin](https://jellyfin.org/) is a free, open-source media server:
- Stream video, music, photos to any device
- Hardware transcoding via GPU/iGPU passthrough (if the host has one)
- Mount media from a NAS via NFS (see Storage section)
- No subscription, no tracking, no cloud dependency

### The *arr Stack (Media Automation)
For automatically managing a media library:
- **Sonarr** — TV show management
- **Radarr** — Movie management
- **Prowlarr** — Indexer management (replaces Jackett)
- **Bazarr** — Subtitle management
- **qBittorrent** or **Transmission** — Download client

These communicate via a shared network and can all use the same NFS media mount.

### Paperless-NGX (Document Management)
[Paperless-NGX](https://docs.paperless-ngx.com/) scans, OCRs, and indexes documents:
- Ingest via email, network share, or direct upload
- Full-text search across all documents
- Tags, correspondents, document types
- Uses the existing PostgreSQL cluster

### Nextcloud (Files, Calendar, Contacts)
[Nextcloud](https://nextcloud.com/) is a self-hosted Dropbox/Google Workspace alternative:
- File sync across devices (desktop + mobile clients)
- CalDAV/CardDAV for calendar and contacts
- Collaborative office documents (Nextcloud Office / Collabora)
- Uses PostgreSQL + Redis

Heavy to operate; evaluate whether simpler alternatives (Syncthing for files, Radicale for CalDAV) meet your needs first.

### Immich (Photo Management)
[Immich](https://immich.app/) is a self-hosted Google Photos alternative with:
- Mobile app backup
- Face recognition, object detection
- Album sharing
- Very active development

---

## 11. AI & Local Intelligence

**Goal:** Run AI models locally for privacy and offline capability.

### Ollama
[Ollama](https://ollama.ai/) runs large language models locally:
- Simple API compatible with OpenAI's format
- Deploy as a Kubernetes Deployment
- GPU passthrough for significantly better performance (optional; runs on CPU)
- Models: Llama 3, Mistral, Phi-3, CodeGemma, etc.

### Open WebUI
[Open WebUI](https://openwebui.com/) is a browser-based chat interface that connects to Ollama:
- Familiar ChatGPT-like UX
- Supports multiple models
- Conversation history stored in PostgreSQL
- SSO via Authentik (OIDC support built in)

### Automatic1111 / ComfyUI — Optional
For image generation (Stable Diffusion). Requires a decent GPU. If no GPU is available, skip.

### Local AI for Automations
Connect Ollama to Home Assistant via the [LocalAI integration](https://www.home-assistant.io/integrations/ollama/) for local voice/text AI in automations — no data leaves the house.

---

## 12. Notifications & Alerting

**Goal:** Get notified about important events without alert fatigue. Alerts should be actionable.

### Ntfy (Push Notifications)
[ntfy](https://ntfy.sh/) is a simple pub/sub notification service:
- Push notifications to Android/iOS via the ntfy app
- Can self-host the server
- Integrate with AlertManager, Kyverno events, backup jobs, etc.

### AlertManager Routing
Configure AlertManager with meaningful routing:
- Critical alerts (disk full, service down, security event) → immediate push via ntfy
- Warning alerts (high resource usage, cert expiry in 14 days) → daily digest
- Info alerts → Grafana only (no push)

Use inhibition rules to prevent alert storms (e.g. suppress individual service alerts if the whole node is down).

### Grafana Alerting
Migrate alert rules from Prometheus AlertManager to Grafana Alerting (unified alerting), which provides:
- Alert rules co-located with dashboards
- Multiple contact points (ntfy, email, Slack webhook, etc.)
- Silence management in the UI

### Watchtower Notifications — Avoid
Watchtower auto-updates containers but is incompatible with GitOps. Use Renovate (see section 1) instead for image update PRs. Watchtower bypasses Git and creates configuration drift.

---

## 13. Database Management

**Goal:** Databases should be easy to inspect, back up, and restore.

### pgAdmin (PostgreSQL Admin UI)
Deploy [pgAdmin 4](https://www.pgadmin.org/) as a pod for browser-based PostgreSQL management:
- Query, inspect tables, manage roles
- Connect to the CloudNative-PG cluster via Service
- Protect behind Authentik forward-auth (do not expose publicly)

### Redis / Valkey
Many applications (Nextcloud, Authentik, Open WebUI, etc.) benefit from a shared Redis cache. Deploy [Valkey](https://valkey.io/) (the open-source Redis fork after the license change) as a shared caching layer:
- Single instance with persistence enabled for a homelab
- Operator: `redis-operator` by OpsTree or a simple StatefulSet

### Database Backup Verification
Beyond taking backups, periodically verify they work:
- A Kubernetes CronJob that restores the latest CloudNative-PG backup to a temporary namespace, runs a smoke test query, then deletes the namespace
- Alerts if the verification job fails

---

## 14. Resource Management

**Goal:** Get the most out of the single node without manual tuning.

### Goldilocks (Resource Recommendations)
[Goldilocks](https://goldilocks.docs.fairwinds.com/) uses the Vertical Pod Autoscaler (VPA) in recommendation mode and displays suggested CPU/memory requests/limits in a dashboard:
- Install VPA in recommendation-only mode (does not auto-change anything)
- Goldilocks reads VPA recommendations and shows them per namespace
- Use the recommendations to right-size resource requests in values.yaml

This is important on a single node where over-requesting starves other workloads and under-requesting causes OOM kills.

### Priority Classes
Define Kubernetes PriorityClasses and assign them to workloads:
- `system-critical`: ArgoCD, cert-manager, Istio control plane
- `homelab-high`: Authentik, monitoring
- `homelab-normal`: User services (Jellyfin, Home Assistant, etc.)
- `homelab-low`: Background jobs, CI runners

When the node is under pressure, low-priority pods are evicted first, keeping critical infrastructure running.

### Pod Disruption Budgets
For StatefulSets (PostgreSQL, Prometheus, etc.), define PodDisruptionBudgets to ensure at least one replica is available during voluntary disruptions (e.g. node drain for OS update with kured).

### Limit Ranges and Resource Quotas
Use Kyverno (already in stack) to auto-generate default LimitRange objects in each namespace, ensuring containers without explicit requests/limits get sensible defaults rather than being able to consume unbounded resources.

---

## 15. Platform UX

**Goal:** Easy to navigate and operate day-to-day, even after not touching it for months.

### Homepage Dashboard
[Homepage](https://gethomepage.dev/) is a highly customizable start page:
- Shows status of all services (HTTP health checks)
- Displays metrics from Prometheus, Pi-hole, etc. via widgets
- Customizable layout with bookmarks
- Deployed as a single container, configured via YAML

The goal: one URL to see everything running and its status.

### Service Catalog in ArgoCD
Ensure every Application in ArgoCD has:
- A meaningful description annotation
- The correct health check configured
- A link annotation pointing to the service's URL

This makes ArgoCD itself a useful service catalog, not just a deploy tool.

### Makefile / Task Improvements
Extend the Makefile (or migrate to [Task](https://taskfile.dev/), a modern `make` replacement with cleaner syntax):
- `task logs SERVICE=authentik` — tail logs for a service
- `task restart SERVICE=pihole` — rollout restart
- `task backup` — trigger a manual Velero backup
- `task open SERVICE=grafana` — open the service URL in a browser
- `task status` — show overall cluster health

### Runbooks as Code
For each service, a short `runbook.md` (or inline in the chart's README) covering:
- How to restart it safely
- Where the logs are
- Common failure modes and fixes
- How to restore from backup

These are invaluable when you haven't touched a service in 6 months and something breaks at 11pm.

### Annotated Sync Waves Diagram
Update the architecture diagram in the README to show which services depend on which, and why they're in their sync wave. Makes it easier for future-you to understand why the deployment order is what it is.

### Automated Health Checks Post-Deploy
Add a post-sync ArgoCD hook (Kubernetes Job) that runs a suite of smoke tests after each sync:
- Can core services be reached?
- Do TLS certificates resolve correctly?
- Is the database accepting connections?

Fail the sync (via the Job exit code) if smoke tests don't pass, preventing silent broken deployments.

---

## Prioritization

| Priority | Item | Effort | Value |
|---|---|---|---|
| High | Renovate Bot for auto-updates | Low | High |
| High | Velero + CloudNative-PG backups | Medium | High |
| High | External DNS | Low | High |
| High | Tailscale operator | Low | High |
| High | Loki log aggregation | Low | High |
| High | Goldilocks resource right-sizing | Low | High |
| Medium | Forgejo + Woodpecker CI | Medium | Medium |
| Medium | Harbor container registry | Medium | Medium |
| Medium | Authentik Blueprints (GitOps auth config) | Medium | High |
| Medium | Homepage dashboard | Low | Medium |
| Medium | Ntfy notifications + AlertManager tuning | Low | Medium |
| Medium | kured for OS reboots | Low | Medium |
| Medium | Enable Falco | Low | Medium |
| Medium | Immich photo management | Low | Medium |
| Medium | Ollama + Open WebUI | Low | Medium |
| Low | Home Assistant stack | Medium | Medium |
| Low | Jellyfin + *arr stack | Medium | Medium |
| Low | Nextcloud | High | Medium |
| Low | Grafana Tempo tracing | Medium | Low |
| Low | Coder dev environments | High | Low |
