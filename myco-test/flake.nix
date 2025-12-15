{
  description = "Myco Managed Service";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }: 
    utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          name = "myco-service";
          src = ./.;
          buildPhase = "mkdir -p $out/bin";
          # FIX: Added shebang via printf so the kernel knows this is a shell script
          installPhase = "printf '#!/bin/sh\\nwhile true; do echo Myco is alive; sleep 5; done' > $out/bin/run && chmod +x $out/bin/run";
        };
      }
    );
}
