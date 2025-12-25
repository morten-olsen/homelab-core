.PHONY: help test-e2e setup-kind install-argocd deploy-bootstrap verify cleanup

CLUSTER_NAME ?= homelab-test
REPO_ROOT := $(shell git rev-parse --show-toplevel)

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

recreate: ## Recreate the kind cluster
	@$(MAKE) cleanup
	@$(MAKE) setup-kind
	@$(MAKE) setup-cluster

setup-cluster:
	@$(MAKE) install-argocd
	@$(MAKE) deploy-homelab

setup-kind: ## Create Kind cluster
	@echo "Setting up Kind cluster..."
	@CLUSTER_NAME=$(CLUSTER_NAME) bash $(REPO_ROOT)/scripts/setup-kind.sh

install-argocd: ## Install ArgoCD
	@echo "Installing ArgoCD..."
	@CLUSTER_NAME=$(CLUSTER_NAME) bash $(REPO_ROOT)/scripts/install-argocd.sh

insert-secrets: ## Insert cluster secrets
	@echo "Inserting secrets..."
	@CLUSTER_NAME=$(CLUSTER_NAME) bash $(REPO_ROOT)/scripts/insert-secrets.sh

deploy-homelab: ## Deploy homelab resources
	@echo "Deploying core..."
	@CLUSTER_NAME=$(CLUSTER_NAME) bash $(REPO_ROOT)/scripts/deploy-homelab.sh

deploy-demo: ## Deploy demo resources
	@echo "Deploying shared..."
	@CLUSTER_NAME=$(CLUSTER_NAME) bash $(REPO_ROOT)/scripts/deploy-demo.sh

cleanup: ## Cleanup Kind cluster
	@echo "Cleaning up..."
	@CLUSTER_NAME=$(CLUSTER_NAME) bash $(REPO_ROOT)/scripts/cleanup.sh
