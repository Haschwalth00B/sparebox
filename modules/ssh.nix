{ config, lib, pkgs, ... }:

{
  services.openssh = {
    enable = true;

    settings = {
      # ── UNCHANGED — no monitor on this box, don't touch login behaviour ──
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;

      # ── reliability additions — don't affect who can log in ─────────────
      ClientAliveInterval = 300;
      ClientAliveCountMax = 3;
      UseDns = false;
      Compression = true;
    };
  };
}

