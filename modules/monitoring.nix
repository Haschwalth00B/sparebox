{ config, lib, pkgs, ... }:

{
  # ── sensors ──────────────────────────────────────────────────────────
  # sensors-detect on this board (HP ProDesk 400 G2 Mini) found exactly one
  # usable chip: coretemp (CPU package temp), confidence 9. No Super-I/O
  # match, no IPMI, no ISA sensors — nothing else to load. sensors-detect's
  # own /etc/sysconfig/lm_sensors output is inert on NixOS (nothing reads
  # it); this is the declarative equivalent.
  boot.kernelModules = [ "coretemp" ];

  # ── SMART / TRIM ─────────────────────────────────────────────────────
  services.smartd.enable = true;
  services.fstrim.enable = true;  # no-op on drives that don't support TRIM

  # ── journald ─────────────────────────────────────────────────────────
  services.journald.extraConfig = ''
    SystemMaxUse=2G
    Compress=yes
    Storage=persistent
  '';

  environment.systemPackages = with pkgs; [
    lm_sensors     # run `sensors-detect` once, manually, after first boot
    smartmontools
    sysstat
    iotop
    nvme-cli
    iperf3
    ethtool
  ];
}

