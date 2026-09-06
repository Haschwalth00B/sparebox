{ config, lib, pkgs, ... }:

{
  networking = {
    hostName = "sparebox";

    wireless.enable       = false;
    networkmanager.enable = false;

    # ── Static IP ───────────────────────────────────────────────────────────
    interfaces.enp3s0 = {
      ipv4.addresses = [{
        address      = "192.168.1.35";
        prefixLength = 24;
      }];
      ipv4.routes = [{
        address      = "0.0.0.0";
        prefixLength = 0;
        via          = "192.168.1.1";
      }];
    };

    resolvconf.enable = true;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
      "8.8.4.4"
    ];

    # ── Firewall ────────────────────────────────────────────────────────────
    firewall.enable = false;
  };

  # ── Network diagnostic tools ──────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    mtr
    nmap
    iftop
    tcpdump
    dig
    whois
    ipcalc
    openssl
  ];
}
