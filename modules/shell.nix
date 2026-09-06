{ config, lib, pkgs, ... }:

{
  # Available system-wide but NOT set as haschwalth's login shell — bash
  # stays default so an SSH session never depends on zsh config parsing
  # cleanly. Run `chsh -s $(which zsh)` yourself if/when you want it default.
  programs.zsh.enable = true;
  programs.starship.enable = true;
  programs.direnv.enable = true;

  environment.shellAliases = {
    k     = "kubectl";
    kgp   = "kubectl get pods";
    kgs   = "kubectl get svc";
    dps   = "docker ps";
    dlogs = "docker logs -f";
    dc    = "docker compose";
    ll    = "eza -la";
    la    = "eza -a";
  };
}

