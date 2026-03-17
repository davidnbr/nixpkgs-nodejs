{
  description = "Flake that exposes Node.js package versions to make easy calling them.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  nixConfig = {
    extra-substituters = [ "https://nixpkgs-nodejs.cachix.org" ];
    extra-trusted-public-keys = [
      "nixpkgs-nodejs.cachix.org-1:zUIFXIRHGVtNSAhYWPDOIpr/4hAvhUEfcRo78RWDgiI="
    ];
  };

  outputs =
    { self, nixpkgs }:
    let
      versionsData = builtins.fromJSON (builtins.readFile ./versions.json);
      versionMap = versionsData.versions;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      lib = rec {
        inherit versionMap;

        hasVersion = { version, ... }: builtins.hasAttr version versionMap;

        getVersionInfo =
          version:
          if builtins.hasAttr version versionMap then
            versionMap.${version}
          else
            throw "Node.js version ${version} not found";

        listVersions = builtins.attrNames versionMap;

        # NOTE: This uses an impure fetchTarball, which is often discouraged
        # in top-level packages, but is sometimes accepted for version pins.
        getNixpkgs =
          { system, version }:
          if hasVersion { inherit version; } then
            let
              info = versionMap.${version};
            in
            import
              (builtins.fetchTarball {
                url = "https://github.com/NixOS/nixpkgs/archive/${info.rev}.tar.gz";
                sha256 = info.sha256;
              })
              {
                inherit system;
                config.allowUnfree = true;
                config.allowInsecurePredicate = (_: true);
              }
          else
            throw "Node.js version ${version} not found in versionMap";
      };

      packagesForSystem =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          perVersionPkgs = builtins.mapAttrs (
            version: _: lib.getNixpkgs { inherit system version; }
          ) versionMap;

          basePackages = builtins.mapAttrs (
            version: versionPkgs:
            let
              attrName = versionMap.${version}.attr or "nodejs";
              attrPath = nixpkgs.lib.splitString "." attrName;
            in
            nixpkgs.lib.attrByPath attrPath (throw "Attribute ${attrName} not found") versionPkgs
          ) perVersionPkgs;

          aliases = nixpkgs.lib.mapAttrs' (
            version: pkg:
            nixpkgs.lib.nameValuePair ("nodejs_" + (builtins.replaceStrings [ "." ] [ "_" ] version)) pkg
          ) basePackages;

          # Create yarn packages bundled with the specific node version.
          # Uses the version-pinned nixpkgs to ensure yarn/node compatibility
          # Falls back to latest nixpkgs if yarn is absent from the pinned rev.
          # yarn.override is a callable attrset (same structure as pnpm); __functionArgs
          # is checked before calling to guard against future packaging changes.
          yarnPackages = nixpkgs.lib.mapAttrs' (
            version: pkg:
            let
              versionPkgs = perVersionPkgs.${version};
              yarnPkgs = if builtins.hasAttr "yarn" versionPkgs then versionPkgs else pkgs;
              yarnOverride = yarnPkgs.yarn.override or null;
              canOverrideNodejs =
                builtins.isAttrs yarnOverride
                && yarnOverride ? __functionArgs
                && builtins.hasAttr "nodejs" yarnOverride.__functionArgs;
            in
            nixpkgs.lib.nameValuePair ("yarn_" + (builtins.replaceStrings [ "." ] [ "_" ] version)) (
              pkgs.symlinkJoin {
                name = "yarn-" + version;
                paths = [
                  pkg
                  (if canOverrideNodejs then yarnOverride { nodejs = pkg; } else yarnPkgs.yarn)
                ];
              }
            )
          ) basePackages;

          # Create pnpm packages bundled with the specific node version.
          # Strategy: use the pnpm that ships in the same pinned nixpkgs as the Node
          # version.
          #
          # Older nixpkgs keep pnpm under nodePackages.pnpm; newer ones promote it to
          # pkgs.pnpm with a callable-attrset override that accepts a nodejs argument.
          # When that override is available we thread
          # our exact Node derivation through it; otherwise we use pnpm as-is.
          #
          # Falls back to latest nixpkgs pnpm only when the pinned rev has no pnpm at
          # all (rare, but guards against evaluation errors).
          pnpmPackages = nixpkgs.lib.mapAttrs' (
            version: pkg:
            let
              versionPkgs = perVersionPkgs.${version};

              pinnedPnpm =
                if builtins.hasAttr "pnpm" versionPkgs then
                  versionPkgs.pnpm
                else
                  versionPkgs.nodePackages.pnpm or null;

              pnpmOverride = if builtins.isNull pinnedPnpm then null else pinnedPnpm.override or null;
              canOverrideNodejs =
                builtins.isAttrs pnpmOverride
                && pnpmOverride ? __functionArgs
                && builtins.hasAttr "nodejs" pnpmOverride.__functionArgs;

              pnpmPkg =
                if builtins.isNull pinnedPnpm then
                  pkgs.pnpm.override { nodejs = pkg; }
                else if canOverrideNodejs then
                  pnpmOverride { nodejs = pkg; }
                else
                  pinnedPnpm;
            in
            nixpkgs.lib.nameValuePair ("pnpm_" + (builtins.replaceStrings [ "." ] [ "_" ] version)) (
              pkgs.symlinkJoin {
                name = "pnpm-" + version;
                paths = [
                  pkg
                  pnpmPkg
                ];
              }
            )
          ) basePackages;
        in
        basePackages // aliases // yarnPackages // pnpmPackages;
    in
    {
      packages = forAllSystems (
        system:
        let
          allPkgs = packagesForSystem system;
        in
        allPkgs // { default = allPkgs."22.22"; }
      );

      overlays.default =
        final: prev:
        let
          pkgsForSystem = packagesForSystem final.system;
        in
        pkgsForSystem;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      # Library functions for integration (compatible with asdf2nix API)
      inherit lib;
    };
}
