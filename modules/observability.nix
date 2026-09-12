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

      outputs.influxdb = [
        {
          urls = [ "http://127.0.0.1:8428" ];
          database = "sparebox";
          skip_database_creation = true;
        }
      ];

      inputs.exec = [
        {
          commands = [
            "/etc/sparebox/scripts/collect-bgp-summary.sh"
          ];
          timeout = "10s";
          data_format = "influx";
        }
      ];
    };
  };

  services.grafana = {
    enable = true;

    settings.server = {
      http_addr = "192.168.1.35";
      http_port = 3000;
    };

    settings.security.secret_key =
      "$__file{/var/lib/grafana/secret_key}";
    
    provision.datasources.settings.datasources = [
      {
    	name = "VictoriaMetrics";
    	uid = "victoriametrics";
    	type = "prometheus";
    	access = "proxy";
    	url = "http://127.0.0.1:8428";
    	isDefault = true;
      }
    ];
    
    provision.dashboards.settings.providers = [
      {
        name = "sparebox";
        options.path = "/etc/grafana/dashboards";
      }
    ];
  };

  systemd.services.grafana.preStart = lib.mkAfter ''
    if [ ! -f /var/lib/grafana/secret_key ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > /var/lib/grafana/secret_key
      chmod 600 /var/lib/grafana/secret_key
    fi
  '';

  networking.firewall.allowedTCPPorts = [
    3000
  ];

  users.users.telegraf.extraGroups = [
    "docker"
  ];

  systemd.services.telegraf = {
    after = [
      "docker.service"
    ];

    wants = [
      "docker.service"
    ];

    path = [
      pkgs.docker
      pkgs.jq
      pkgs.bash
    ];
  };

  environment.etc."sparebox/scripts/collect-bgp-summary.sh" = {
    source = ../containerlab/scripts/metrics/collect-bgp-summary.sh;
    mode = "0755";
  };

  environment.etc."grafana/dashboards/topology-health.json".source =
    ../grafana/dashboards/topology-health.json;
}

