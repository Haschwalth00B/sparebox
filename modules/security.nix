{ config, lib, pkgs, ... }:

{
  # ── sudo ──────────────────────────────────────────────────────────────
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=15
  '';

  # ── fail2ban ─────────────────────────────────────────────────────────
  # OFF by default. This box has no monitor/IPMI — a mistyped password a
  # few times from your own IP could ban yourself out with no way back in
  # except pulling the drive. Flip `enable` to true once `ignoreIP` covers
  # every network you'll actually SSH in from.
  services.fail2ban = {
    enable = false;
    maxretry = 10;
    bantime = "1h";
    ignoreIP = [
      "127.0.0.0/8"
      "192.168.1.0/24"  # home LAN
      "100.64.0.0/10"   # Tailscale CGNAT range
    ];
  };

  # ── automatic security updates ─────────────────────────────────────────
  # OFF by default, same reasoning. allowReboot stays false even once you
  # enable this: `nixos-rebuild switch` can apply a new generation live
  # without a reboot, so SSH access is never gated on a reboot succeeding.
  system.autoUpgrade = {
    enable = false;
    allowReboot = false;
    dates = "04:30";
    flake = "github:Haschwalth00B/nixos-configuration-files#sparebox";
  };

  # ── firewall ─────────────────────────────────────────────────────────
  # Stays disabled in modules/networking.nix, intentionally not touched here.

  # ── audit ────────────────────────────────────────────────────────────
  # Not enabled — no auditd / syscall auditing overhead for now.
}

