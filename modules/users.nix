{ config, lib, pkgs, ... }:

{
  users.users.haschwalth = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    };
  security.sudo.wheelNeedsPassword = true;
}
