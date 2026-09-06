{ config, lib, pkgs, ... }:

{
  # ── KVM / libvirt ────────────────────────────────────────────────────
  # OFF by default — nothing in the current project needs VM-level
  # virtualisation yet (Containerlab uses containers, not VMs). Flip
  # `enable` to true when you actually need to spin up VMs for testing.
  virtualisation.libvirtd.enable = lib.mkDefault false;
  virtualisation.spiceUSBRedirection.enable = false;

  environment.systemPackages = with pkgs;
    lib.optionals config.virtualisation.libvirtd.enable [
      virt-manager
      qemu
      OVMF
    ];

  # Only adds haschwalth to the libvirtd group if libvirtd is actually
  # enabled — referencing a group that doesn't exist would fail eval.
  users.users.haschwalth.extraGroups =
    lib.mkIf config.virtualisation.libvirtd.enable [ "libvirtd" ];
}

