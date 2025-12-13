{ pkgs, lib, config, inputs, ... }:

{
  env.GREET = "devenv";

  packages = [ pkgs.nix-prefetch-git pkgs.jq];
}
