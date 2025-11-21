{
  description = "asdf2nix nodejs plugin with minor version support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Load versions from versions.json
      versionsData = builtins.fromJSON (builtins.readFile ./versions.json);
      versionMap = versionsData.versions;
      
      # Supported systems
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      
      # Helper to create packages for a system
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      
      # Create a Node.js package for a specific version and system
      mkNodePackage = system: version: versionInfo:
        let
          # Fetch nixpkgs at the specific commit
          pkgsForVersion = import (builtins.fetchTarball {
            url = "https://github.com/NixOS/nixpkgs/archive/${versionInfo.rev}.tar.gz";
            sha256 = versionInfo.sha256;
          }) {
            inherit system;
            config.allowUnfree = true;
          };
        in
          pkgsForVersion.nodejs;
      
      # Generate all packages for a given system
      packagesForSystem = system:
        builtins.mapAttrs
          (version: versionInfo: mkNodePackage system version versionInfo)
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
      lib = rec {
        inherit versionMap;
        
        # Check if a version exists for a given system
        # API: hasVersion { system = "x86_64-linux"; version = "20.18"; }
        hasVersion = { system, version }:
          builtins.hasAttr version versionMap;
        
        # Get version info
        getVersionInfo = version: 
          if builtins.hasAttr version versionMap
          then versionMap.${version}
          else throw "Node.js version ${version} not found";
        
        # List all available versions
        listVersions = builtins.attrNames versionMap;
        
        # Get the nixpkgs for a specific version
        getNixpkgs = { system, version }:
          if hasVersion { inherit system version; }
          then
            import (builtins.fetchTarball {
              url = "https://github.com/NixOS/nixpkgs/archive/${versionMap.${version}.rev}.tar.gz";
              sha256 = versionMap.${version}.sha256;
            }) { inherit system; config.allowUnfree = true; }
          else throw "Node.js version ${version} not found in versionMap";
        
        # Get Node.js package for a specific version
        getNodejs = { system, version }:
          (getNixpkgs { inherit system version; }).nodejs;
      };
      
      # Binary cache configuration (update after Cachix setup)
      nixConfig = {
        extra-substituters = [ "https://nixpkgs-nodejs.cachix.org" ];
        extra-trusted-public-keys = [
          "nixpkgs-nodejs.cachix.org-1:PLACEHOLDER_REPLACE_AFTER_CACHIX_SETUP="
        ];
      };
    };
}

