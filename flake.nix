{
  description = "Homelab Core - ArgoCD App-of-Apps deployment with e2e testing";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        
        # Wrapper script for kubeseal with controller flags
        kubeseal-wrapped = pkgs.writeShellScriptBin "kubeseal" ''
          exec ${pkgs.kubeseal}/bin/kubeseal --controller-namespace core --controller-name sealed-secrets-operator "$@"
        '';
      in
      {
        devShells.default = pkgs.mkShell {
          name = "homelab-core";

          buildInputs = with pkgs; [
            # Kubernetes tools
            kubectl
            kubernetes-helm
            kind
            kubeseal-wrapped  # Use wrapped version instead of direct kubeseal

            # Build tools
            gnumake

            # Git
            git

            # Shell utilities
            bash
            coreutils
            jq
            curl

            # Optional: kubectx/kubens for easier cluster management
            kubectx

            # Optional: k9s for cluster inspection
            k9s
          ];

          shellHook = ''
            echo "🚀 Homelab Core Development Environment"
            echo ""
            echo "Available tools:"
            echo "  kubectl: $(kubectl version --client --short 2>/dev/null | head -n1 || echo 'not available')"
            echo "  helm: $(helm version --client --short 2>/dev/null || echo 'not available')"
            echo "  kind: $(kind --version 2>/dev/null || echo 'not available')"
            echo ""
            echo "Quick start:"
            echo "  make test-e2e          # Run full e2e test suite"
            echo "  make setup-kind        # Create Kind cluster"
            echo "  make install-argocd    # Install ArgoCD"
            echo ""
            echo "Note: Ensure Docker is running for Kind clusters"
            echo ""
            echo "kubeseal is configured with: --controller-namespace core --controller-name sealed-secrets-operator"
          '';
        };

        # Formatter for nix files
        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
