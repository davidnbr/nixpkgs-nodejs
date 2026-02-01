{
  description = "asdf2nix nodejs plugin with minor version support";

  inputs = {
    # Keep the main nixpkgs input for lib functions and utilities
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      versionsData = builtins.fromJSON (builtins.readFile ./versions.json);
      versionMap = versionsData.versions;

      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      lib = rec {
        inherit versionMap;

        hasVersion = { version, ... }:
          builtins.hasAttr version versionMap;

        getVersionInfo = version: 
          if builtins.hasAttr version versionMap
          then versionMap.${version}
          else throw "Node.js version ${version} not found";

        listVersions = builtins.attrNames versionMap;

        # NOTE: This uses an impure fetchTarball, which is often discouraged
        # in top-level packages, but is sometimes accepted for version pins.
        getNixpkgs = { system, version }:
          if hasVersion { inherit version; }
          then
            let
              info = versionMap.${version};
            in
            import (builtins.fetchTarball {
              url = "https://github.com/NixOS/nixpkgs/archive/${info.rev}.tar.gz";
              sha256 = info.sha256;
            }) { inherit system; config.allowUnfree = true; config.allowInsecurePredicate = (_: true);}
          else throw "Node.js version ${version} not found in versionMap";

        getNodejs = { system, version }:
          let
            pkgs = getNixpkgs { inherit system version; };
            attrName = versionMap.${version}.attr or "nodejs";
            attrPath = nixpkgs.lib.splitString "." attrName;
          in
            nixpkgs.lib.attrByPath attrPath (throw "Attribute ${attrName} not found") pkgs;
      };

      # Generate all packages for a given system
      packagesForSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          
          basePackages = builtins.mapAttrs
            (version: versionInfo: lib.getNodejs { inherit system version; })
            versionMap;
          
          # Create aliases like nodejs_20_18 for 20.18
          aliases = nixpkgs.lib.mapAttrs'
            (version: pkg: nixpkgs.lib.nameValuePair 
              ("nodejs_" + (builtins.replaceStrings ["."] ["_"] version)) 
              pkg
            )
            basePackages;

          # Create yarn packages bundled with the specific node version
          yarnPackages = nixpkgs.lib.mapAttrs'
            (version: pkg: nixpkgs.lib.nameValuePair 
              ("yarn_" + (builtins.replaceStrings ["."] ["_"] version)) 
              (pkgs.symlinkJoin {
                name = "yarn-" + version;
                paths = [ (pkgs.yarn.override { nodejs = pkg; }) pkg ];
              })
            )
            basePackages;

          # Create pnpm packages bundled with the specific node version
          pnpmPackages = nixpkgs.lib.mapAttrs'
            (version: pkg: nixpkgs.lib.nameValuePair 
              ("pnpm_" + (builtins.replaceStrings ["."] ["_"] version)) 
              (pkgs.symlinkJoin {
                name = "pnpm-" + version;
                paths = [ (pkgs.pnpm.override { nodejs = pkg; }) pkg ];
              })
            )
            basePackages;
        in
          basePackages // aliases // yarnPackages // pnpmPackages;
    in
    {
      # Standard Flake Outputs
      packages = forAllSystems (system: 
        (packagesForSystem system) // {
          # Default to latest LTS (22.22)
          default = (packagesForSystem system)."22.22";
        }
      );

      # Overlay allows users to use these packages in their own nixpkgs instance
      overlays.default = final: prev: 
        let
          # We need to compute packages for the specific system of the final pkgs
          pkgsForSystem = packagesForSystem final.system;
        in
          pkgsForSystem;

      # Formatter for the project
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      # Library functions for integration (compatible with asdf2nix API)
      inherit lib;

      nixConfig = {
        extra-substituters = [ "https://nixpkgs-nodejs.cachix.org" ];
        extra-trusted-public-keys = [
          "nixpkgs-nodejs.cachix.org-1:zUIFXIRHGVtNSAhYWPDOIpr/4hAvhUEfcRo78RWDgiI="
        ];
      };
    };
}
