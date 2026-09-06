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
          ./hardware-configuration.nix

          # boot / kernel / nix daemon
          ./modules/boot.nix
          ./modules/kernel.nix
          ./modules/nix.nix

          # access — these are the modules that determine whether this box
          # stays reachable at all. losing any one of them previously took
          # SSH down with no console/IPMI to recover from.
          # modules/safety-assertions.nix now fails the *build* instead of
          # failing the box if one of them goes missing again.
          ./modules/networking.nix
          ./modules/ssh.nix
          ./modules/security.nix
          ./modules/users.nix
          ./modules/safety-assertions.nix

          # workload platform (base)
          ./modules/docker.nix
          ./modules/virtualization.nix
          ./modules/monitoring.nix

          # packages / shell
          ./modules/packages.nix
          ./modules/shell.nix

          # sparebox project modules
          ./modules/network-fabric.nix
          ./modules/k3s-platform.nix
          ./modules/observability.nix
          ./modules/secrets.nix

          ({ ... }: {
            time.timeZone = "Asia/Kolkata";

            swapDevices = [
              { device = "/swapfile"; size = 16 * 1024; }
            ];

            system.stateVersion = "26.05";
          })
        ];
      };
    };
}
