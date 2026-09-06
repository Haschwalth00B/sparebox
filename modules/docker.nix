{ config, lib, pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;

    daemon.settings = {
      log-driver = "json-file";
      log-opts = {
        max-size = "10m";
        max-file = "3";
      };
      features.buildkit = true;
    };

    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ "--filter" "until=240h" ]; # keep anything touched in last 10 days
    };
  };

  environment.systemPackages = with pkgs; [
    docker-compose  # gives you `docker-compose`; symlink it into
                    # ~/.docker/cli-plugins/docker-compose if you also
                    # want the `docker compose` (space) subcommand form
    lazydocker
    dive
  ];

  # haschwalth already has extraGroups = [ "wheel" "docker" ] in modules/users.nix
}

