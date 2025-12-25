# Dev Container

This directory contains the devcontainer configuration for VS Code/Cursor.

## Features

- **Docker-in-Docker**: Full Docker support for Kind clusters
- **Kubernetes Tools**: kubectl and Helm pre-installed
- **Kind**: Kubernetes cluster manager
- **Git**: Version control
- **VS Code Extensions**: Kubernetes, YAML, Makefile, and Nix support

## Usage

1. Open the repository in VS Code or Cursor
2. When prompted, click "Reopen in Container"
3. Or use Command Palette: "Dev Containers: Reopen in Container"

## Port Forwarding

The devcontainer automatically forwards:
- Port 30080: ArgoCD HTTP UI
- Port 30443: ArgoCD HTTPS UI

## Requirements

- Docker Desktop or Docker Engine
- VS Code or Cursor with Dev Containers extension

## First Run

After the container starts, you can immediately run:

```bash
make test-e2e
```

All dependencies are pre-installed and configured.
