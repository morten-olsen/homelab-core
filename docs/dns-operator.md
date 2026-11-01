# DNS operator recovery

The DNS operator is installed by `charts/core` into the existing `falco` namespace.
Its DNSClass and DNSRecord objects are retained during chart rollbacks.

Published chart `0.0.10` renders the manager image as `/:0.0.10` with its default
values. Kubernetes rejects it with `InvalidImageName`; the rolling Deployment
keeps the older ready pod but eventually reports `ProgressDeadlineExceeded`, and
ArgoCD becomes Degraded. HOMEIT-510 reproduced this by rendering the published
chart, rather than assuming an image-pull or DNS/network failure.

The recovery selects the previously running chart `0.0.8`, whose manager image is
`ghcr.io/morten-olsen/homelab-dns-operator:0.0.8`. Renovate excludes only the broken
`0.0.10` chart; other versions remain eligible for normal reviewed updates.
Chart `0.0.9` also renders a complete image name, but was not running before this
incident and is not the recovery target.

Before accepting another DNS operator chart update, render the published artifact
and verify the actual image reference, then server-dry-run the Deployment:

```sh
helm template dns-operator dns-operator \
  --repo https://morten-olsen.github.io/homelab-dns-operator \
  --version <version> --namespace falco > /tmp/dns-operator.yaml
yq 'select(.kind == "Deployment")' /tmp/dns-operator.yaml \
  | kubectl apply --dry-run=server -f -
```

After reconciliation, check Application revision/health, the Deployment image and
ready replicas, disappearance of the invalid-image pod, and DNSRecord conditions
and DNS resolution. Do not change records, credentials, namespace or CRDs to
repair an invalid image reference.
