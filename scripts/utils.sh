#!/bin/bash
# Utility functions for e2e test scripts

# Wait for an ArgoCD Application to be synced and healthy
# Usage: wait-for-arg-app <app-name> [timeout-seconds] [namespace]
# Default timeout: 600 seconds (10 minutes)
# Default namespace: argocd
wait-for-arg-app() {
  local app_name="${1}"
  local timeout="${2:-600}"
  local namespace="${3:-argocd}"
  
  if [ -z "$app_name" ]; then
    echo "ERROR: wait-for-arg-app requires an application name"
    return 1
  fi
  
  # KUBECTL_CMD should be set by the calling script
  if [ -z "${KUBECTL_CMD:-}" ]; then
    echo "ERROR: KUBECTL_CMD is not set"
    return 1
  fi
  
  echo "Waiting for ArgoCD Application: $app_name..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    if ! ${KUBECTL_CMD} get application/"$app_name" -n "$namespace" &>/dev/null; then
      echo "  Application not found yet (${elapsed}s/${timeout}s)"
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    fi
    
    local sync_status=$(${KUBECTL_CMD} get application/"$app_name" -n "$namespace" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    local health_status=$(${KUBECTL_CMD} get application/"$app_name" -n "$namespace" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
      echo "✓ Application $app_name is synced and healthy"
      return 0
    fi
    
    echo "  Status: sync=$sync_status, health=$health_status (${elapsed}s/${timeout}s)"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  
  echo "ERROR: Application $app_name did not become healthy within ${timeout}s"
  ${KUBECTL_CMD} describe application/"$app_name" -n "$namespace"
  return 1
}
