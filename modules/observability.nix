# modules/observability.nix
#
# Week 5 metrics pipeline, step 1: Telegraf -> VictoriaMetrics, running as
# host-level NixOS services (not injected into the containerlab topology
# itself). Telegraf reaches into the router containers via `docker exec`,
# the same way BGP/LDP/MPLS state has been verified by hand all through
# Week 5 -- this just automates and schedules that.
#
# Scope of this step: BGP peer state only (collect-bgp-summary.sh).
# OSPF, LDP/VPNv4 VRF state, interface counters, and IPsec tunnel status
# are separate inputs.exec entries to add once this slice is confirmed
# flowing end-to-end -- not folded in here, so a bad jq path in a later
# collector can't take down a working one.
{ config, pkgs, lib, ... }:

{
  services.victoriametrics = {
    enable = true;
    retentionPeriod = "30d";
    listenAddress = "127.0.0.1:8428";
  };

  services.telegraf = {
    enable = true;
    extraConfig = {
      agent = {
        interval = "15s";
        round_interval = true;
        flush_interval = "15s";
      };

      # VictoriaMetrics' single-node binary accepts InfluxDB line protocol
      # on its /write endpoint, so Telegraf can talk to it as a plain
      # InfluxDB output with no VM-specific plugin needed.
      outputs.influxdb = [{
        urls = [ "http://127.0.0.1:8428" ];
        database = "sparebox";
        skip_database_creation = true;
      }];

      inputs.exec = [{
        commands = [ "/etc/sparebox/scripts/collect-bgp-summary.sh" ];
        timeout = "10s";
        data_format = "influx";
      }];
    };
  };

  # telegraf's exec input shells out to `docker exec` against the
  # containerlab node containers, so it needs docker group membership
  # and docker.service up before it starts scraping.
  users.users.telegraf.extraGroups = [ "docker" ];
  systemd.services.telegraf = {
    after = [ "docker.service" ];
    wants = [ "docker.service" ];
    path = [ pkgs.docker pkgs.jq pkgs.bash ];
  };

  environment.etc."sparebox/scripts/collect-bgp-summary.sh" = {
    source = ../containerlab/scripts/metrics/collect-bgp-summary.sh;
    mode = "0755";
  };
}
