#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab-test}"
KUBECTL_CMD="kubectl --context=kind-${CLUSTER_NAME}"

echo "Installing ArgoCD..."

# Create argocd namespace
${KUBECTL_CMD} create namespace argocd --dry-run=client -o yaml | ${KUBECTL_CMD} apply -f -

# Install ArgoCD using Helm
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 9.2.1 \
  --set configs.params.server.insecure=true \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30080 \
  --set server.service.nodePortHttps=30443 \
  --set repoServer.livenessProbe.timeoutSeconds=10 \
  --set repoServer.livenessProbe.initialDelaySeconds=30 \
  --set repoServer.readinessProbe.timeoutSeconds=10 \
  --wait \
  --timeout 10m

echo "Waiting for ArgoCD to be ready..."
${KUBECTL_CMD} wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d >argo-password.txt
echo "ArgoCD installed successfully!"
echo "ArgoCD UI available at: http://localhost:30080"
