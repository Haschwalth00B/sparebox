# modules/safety-assertions.nix
#
# Exists because of one specific incident: an earlier version of this flake
# built and switched fine but never imported ssh.nix, networking.nix,
# users.nix, or security.nix -- the switch succeeded, silently dropped
# sshd and the reachable network config, and this box has no monitor/IPMI
# to recover through, only a console rollback.
#
# These assertions turn "the resulting system would be unreachable" into a
# build-time failure instead of a runtime one -- dry-build (or even plain
# eval) catches it before anything is ever activated on the real box.
{ config, lib, ... }:

{
  assertions = [
    {
      assertion = config.services.openssh.enable;
      message = ''
        services.openssh.enable is false. This box has no console/IPMI --
        shipping this would lock out SSH access with no way back in short
        of physical access and a rollback. Import modules/ssh.nix.
      '';
    }
    {
      assertion = !config.networking.firewall.enable
        || builtins.elem 22 config.networking.firewall.allowedTCPPorts;
      message = ''
        networking.firewall.enable is true but port 22 is not in
        allowedTCPPorts. Either keep the firewall disabled (current
        default, set in modules/networking.nix) or explicitly allow 22
        before ever enabling it.
      '';
    }
    {
      assertion = config.users.users ? haschwalth
        && config.users.users.haschwalth.isNormalUser;
      message = ''
        the haschwalth user is missing or not a normal user. Import
        modules/users.nix.
      '';
    }
  ];
}
