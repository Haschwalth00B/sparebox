{ pkgs, ... }:

{
  # FRR and strongSwan run inside Containerlab-managed containers.
  virtualisation.docker.enable = true;

  environment.systemPackages = with pkgs; [
    containerlab
  ];

  # Restore the fabric after Docker starts during system boot.
  systemd.services.sparebox-fabric = {
    description = "Sparebox Containerlab fabric recovery";

    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [ "docker.service" ];

    path = with pkgs; [
      bash
      coreutils
      docker
      containerlab
      iproute2
      gnugrep
      gawk
      jq
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/root/sparebox";
      TimeoutStartSec = "10min";
    };

    script = ''
      exec ${pkgs.bash}/bin/bash \
        /root/sparebox/containerlab/scripts/boot-recover.sh
    '';
  };
}
