{ config, lib, pkgs, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Flip to true only if a package you need (vendor tooling, some firmware,
  # etc.) requires an unfree license — everything shipped in this config
  # as-is is free/open-source.
  nixpkgs.config.allowUnfree = false;
}

