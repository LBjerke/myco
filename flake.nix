{
  description = "Development environment for the Sovereign Cloud Orchestrator";

  # --- Flake Inputs ---
  # This section defines the external dependencies of our flake.
  inputs = {
    # Nixpkgs is the main Nix package repository. We pin it to a specific version for reproducibility.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The flake-utils library helps us easily define outputs for different systems (x86_64, aarch64).
    flake-utils.url = "github:numtide/flake-utils";
    dagger.url = "github:dagger/nix";
    dagger.inputs.nixpkgs.follows = "nixpkgs";
  };

  # --- Flake Outputs ---
  # This section defines what our flake provides (packages, shells, etc.).
  outputs = { self, nixpkgs, flake-utils, dagger }:
    # Use flake-utils to generate outputs for common systems.
    flake-utils.lib.eachDefaultSystem (system:
      let
        # 'pkgs' is a shortcut for the package set for the current system (e.g., x86_64-linux).
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # --- The Development Shell ---
        # This is the main output we care about for development.
        # You can enter this environment by running `nix develop`.
        devShells.default = pkgs.mkShell {
          
          # A welcoming message when you enter the shell.
          name = "sovereign-orchestrator-dev-shell";
          shellHook = ''
            echo "--- Sovereign Orchestrator Development Environment ---"
            echo "Available tools: zig, gitea, dagger, fossil, go"
            echo "Run 'zig build' to build the project."
            echo "----------------------------------------------------"
          '';

          # --- Build Inputs: Libraries and Headers ---
          # These packages are needed at COMPILE time. Their headers and .a/.so files
          # will be available to the Zig compiler.
          buildInputs = with pkgs; [
            # The core language toolchain for Zig
            zig

            # --- C Libraries for Native Integration ---
            # For Git/Fossil (you might choose one, but having both is fine for dev)
            libgit2  # For the Git backend approach
            fossil   # For the Fossil backend approach (provides the library)
            
            # For P2P networking
            zeromq   # ZMQ dependency
            czmq     # High-level C binding for ZMQ (often needed by Zyre)
            # Note: Zyre is not in the main nixpkgs yet, so it might need to be
            # packaged separately or built from source if czmq isn't enough.
            # We'll add it conceptually here.
            
            # For bootstrapping/remote execution
            libssh2

            # For the Dagger CI/CD pipeline in Go
            go
            
            # Standard build tools that are often useful
            pkg-config
            openssl
          ];

          # --- Native Build Inputs: Tools for the Shell ---
          # These packages provide command-line tools you want to use interactively
          # within the development shell.
          packages = with pkgs; [
            # For testing your Gitea CI/CD setup locally
            gitea
            
            # The Dagger CLI/engine for running your pipeline
            dagger.packages.${system}.dagger
            # For interacting with your cluster's Fossil repo
            fossil
          ];
        };
      }
    );
}
