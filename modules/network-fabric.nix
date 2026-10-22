{ pkgs, ... }:

let
  fabricRecoveryFiles = pkgs.runCommand "sparebox-fabric-recovery-files" {} ''
    mkdir -p "$out/containerlab/scripts"
    mkdir -p "$out/containerlab/chaos"
    mkdir -p "$out/containerlab/strongswan"
    cp ${../containerlab/recovery-data-links.tsv} "$out/containerlab/recovery-data-links.tsv"

    cp ${../containerlab/scripts/boot-recover.sh} "$out/containerlab/scripts/boot-recover.sh"
    cp ${../containerlab/scripts/restore-data-links.sh} "$out/containerlab/scripts/restore-data-links.sh"
    cp ${../containerlab/scripts/setup-cust-a.sh} "$out/containerlab/scripts/setup-cust-a.sh"
    cp ${../containerlab/chaos/inject.sh} "$out/containerlab/chaos/inject.sh"

    ${pkgs.coreutils}/bin/mkdir -p "$out/containerlab/strongswan"
    ${pkgs.coreutils}/bin/cp -r ${../containerlab/strongswan}/. "$out/containerlab/strongswan/"
  '';
in
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
      util-linux
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
        ${fabricRecoveryFiles}/containerlab/scripts/boot-recover.sh
    '';
  };
}
