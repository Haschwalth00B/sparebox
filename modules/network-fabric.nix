{ pkgs, ... }:
{
  # Everything Phase 1 actually needs at the host level — FRR and strongSwan
  # themselves run as Containerlab-launched Docker containers, not host
  # services, so this module stays small.

  virtualisation.docker.enable = true;

  environment.systemPackages = with pkgs; [
    containerlab
  ];
}
