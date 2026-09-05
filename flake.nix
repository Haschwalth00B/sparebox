{
  description = "sparebox — SRE/infra homelab capstone (network fabric + k3s platform)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # sops-nix.url = "github:Mic92/sops-nix"; # wire in when secrets module is written
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
    in {
      nixosConfigurations.sparebox = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/network-fabric.nix
          ./modules/k3s-platform.nix
          ./modules/observability.nix
          ./modules/secrets.nix
          ({ pkgs, ... }: {
            networking.hostName = "sparebox";
            system.stateVersion = "26.05";

            # TODO: fill in for the real box — this skeleton hasn't been
            # applied against actual hardware yet.
            # boot.loader.systemd-boot.enable = true;
            # boot.loader.efi.canTouchEfiVariables = true;
            # fileSystems."/" = { device = "/dev/disk/by-uuid/CHANGE-ME"; fsType = "ext4"; };

            # users.users.<youruser> = {
            #   isNormalUser = true;
            #   extraGroups = [ "wheel" "docker" ];
            # };
          })
        ];
      };
    };
}
