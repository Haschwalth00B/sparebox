{ pkgs, ... }:
{
  # sops-nix at the host level, age-encrypted, same age key Flux uses for
  # its own in-cluster SOPS decryption (Phase 2, ~Week 12). Not wired in
  # yet — no secrets exist to manage until then.

  # imports = [ inputs.sops-nix.nixosModules.sops ];
  # sops.defaultSopsFile = ../secrets/secrets.yaml;
  # sops.age.keyFile = "/var/lib/sops-nix/key.txt";
}
