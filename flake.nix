    #dagger.url = "github:dagger/nix";
    #dagger.inputs.nixpkgs.follows = "nixpkgs";
    #dagger.packages.${system}.dagger
  {
  description = "Sovereign Cloud Orchestrator (Myco) Development and CI Environment";

  # Nixpkgs version to use.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.dagger.url = "github:dagger/nix";
  inputs.dagger.inputs.nixpkgs.follows = "nixpkgs";
  inputs.rainyday-vim.url = "github:LBjerke/rainyday-vim";

  outputs = { self, nixpkgs, dagger, rainyday-vim, ... }:
    let
      # --- Boilerplate from the reference flake ---
      # System types to support.
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Nixpkgs instantiated for each supported system type.
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; overlays = [ rainyday-vim.overlays.default];});

      # --- Our Project-Specific Logic ---
      # Function to get the list of build-time dependencies for a given pkgs set.
      getBuildDependencies = pkgs: with pkgs; [
        zig
        libgit2
        fossil
        zeromq
        czmq
        libssh2
        pkg-config
        openssl
      ];
      
      # Function to build our orchestrator package for a given pkgs set.
      mkOrchestratorPkg = pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "orchestrator";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = getBuildDependencies pkgs;
          buildPhase = ''
            zig build -Doptimize=ReleaseSafe --prefix $out
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/orchestrator $out/bin/
          '';
        };

    in
    {
      # --- Packages ---
      # Generate the 'packages' output for all supported systems.
      packages = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = mkOrchestratorPkg pkgs;
        });

      # --- Default Package ---
      # The default package for 'nix build' on any supported system.
      defaultPackage = forAllSystems (system: self.packages.${system}.default);

      # --- Development Shells ---
      # Generate the 'devShells' output for all supported systems.
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          # 1. The Default, Rich Development Shell
          default = pkgs.mkShell {
            name = "myco-dev-shell";
            packages = with pkgs; (getBuildDependencies pkgs) ++ [
    dagger.packages.${system}.dagger
              go
              nvim-pkg
              gitea
              gitea-actions-runner
              gemini-cli
              python313Packages.lizard
            ];
          };

          # 2. The Minimal CI Shell
          ci = pkgs.mkShell {
            name = "myco-ci-shell";
          ##  buildInputs = getBuildDependencies pkgs;
            # This is the key for native cross-compilation.
            # It adds the aarch64 toolchain to the x86_64 shell.
            packages = with pkgs; (getBuildDependencies pkgs) ++ (
              # Use `lib.optionals` for a cleaner conditional check.
              nixpkgs.lib.optionals (system == "x86_64-linux") [
                pkgs.pkgsCross.aarch64-multiplatform
              ]
            );
          };
        });
    };
}
