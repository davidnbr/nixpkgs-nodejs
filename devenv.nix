{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

{
  cachix.pull = [
    "nix-community"
  ];
  env.GREET = "devenv";

  packages = [
    pkgs.nix-prefetch-git
    pkgs.jq
    pkgs.nixfmt
    pkgs.nixfmt-tree
    pkgs.nixpkgs-lint
  ];
}
