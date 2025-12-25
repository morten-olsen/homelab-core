#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab-test}"

echo "Creating Kind cluster: ${CLUSTER_NAME}"

# Create kind cluster configuration
# Note: No ingress configuration as Istio will handle ingress
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
    protocol: TCP
  - containerPort: 30443
    hostPort: 30443
    protocol: TCP
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
EOF

echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s --context="kind-${CLUSTER_NAME}"

# Remove the exclude-from-external-load-balancers label from control plane node
# This allows LoadBalancer services to work on control plane nodes (default in kind)
echo "Configuring control plane node for LoadBalancer services..."
kubectl label node "${CLUSTER_NAME}-control-plane" --context="kind-${CLUSTER_NAME}" node.kubernetes.io/exclude-from-external-load-balancers- --overwrite || true

echo "Installing cloud-provider-kind..."
CLOUD_PROVIDER_KIND_VERSION="${CLOUD_PROVIDER_KIND_VERSION:-v0.10.0}"
CLOUD_PROVIDER_KIND_IMAGE="registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CLOUD_PROVIDER_KIND_VERSION}"

# Pull the image if not already present
docker pull "${CLOUD_PROVIDER_KIND_IMAGE}" || true

# Stop any existing cloud-provider-kind container for this cluster
docker stop "cloud-provider-kind-${CLUSTER_NAME}" 2>/dev/null || true
docker rm "cloud-provider-kind-${CLUSTER_NAME}" 2>/dev/null || true

# Run cloud-provider-kind as a Docker container with access to Docker socket and kind network
echo "Starting cloud-provider-kind container..."
docker run -d \
  --name "cloud-provider-kind-${CLUSTER_NAME}" \
  --network "kind" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --restart unless-stopped \
  "${CLOUD_PROVIDER_KIND_IMAGE}"

echo "Waiting for cloud-provider-kind to be ready..."
sleep 5

# Verify cloud-provider-kind is running
if docker ps | grep -q "cloud-provider-kind-${CLUSTER_NAME}"; then
  echo "cloud-provider-kind is running successfully!"
else
  echo "Warning: cloud-provider-kind container may not be running. Check logs with: docker logs cloud-provider-kind-${CLUSTER_NAME}"
fi

echo "Kind cluster created successfully with cloud-provider-kind!"
