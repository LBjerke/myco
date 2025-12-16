pub const FLAKE_NIX =
    \\{
    \\  description = "Myco Managed Service";
    \\
    \\  inputs = {
    \\    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    \\    utils.url = "github:numtide/flake-utils";
    \\  };
    \\
    \\  outputs = { self, nixpkgs, utils }: 
    \\    utils.lib.eachDefaultSystem (system:
    \\      let pkgs = nixpkgs.legacyPackages.${system}; in
    \\      {
    \\        packages.default = pkgs.stdenv.mkDerivation {
    \\          name = "myco-service";
    \\          src = ./.;
    \\          buildPhase = "mkdir -p $out/bin";
    \\          # FIX: Added shebang via printf so the kernel knows this is a shell script
    \\          installPhase = "printf '#!/bin/sh\\necho Hello from Myco!' > $out/bin/run && chmod +x $out/bin/run";
    \\        };
    \\      }
    \\    );
    \\}
;

pub const MYCO_JSON =
    \\{
    \\  "name": "my-first-service",
    \\  "requirements": {
    \\    "arch": ["x86_64-linux", "aarch64-linux"],
    \\    "ram_mb": 128
    \\  }
    \\}
;
