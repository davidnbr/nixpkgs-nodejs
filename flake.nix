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
            }) { inherit system; config.allowUnfree = true; }
          else throw "Node.js version ${version} not found in versionMap";

        getNodejs = { system, version }:
          (getNixpkgs { inherit system version; }).nodejs;
      };

      # Generate all packages for a given system
      packagesForSystem = system:
        builtins.mapAttrs
          (version: versionInfo: lib.getNodejs { inherit system version; })
          versionMap;
    in
    {
      # Packages for all systems
      packages = forAllSystems (system: 
        (packagesForSystem system) // {
          # Default to latest LTS (20.18)
          default = (packagesForSystem system)."20.18";
        }
      );

      # Library functions for integration (compatible with asdf2nix API)
      inherit lib;

      # Binary cache configuration (update after Cachix setup)
      nixConfig = {
        extra-substituters = [ "https://nixpkgs-nodejs.cachix.org" ];
        extra-trusted-public-keys = [
          "nixpkgs-nodejs.cachix.org-1:PLACEHOLDER_REPLACE_AFTER_CACHIX_SETUP="
        ];
      };
    };
}
