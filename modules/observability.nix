{ pkgs, ... }:
{
  # Week 5's Telegraf -> VictoriaMetrics piece is the first thing that
  # belongs here — host-level metrics collection exists before k3s does.
  # In-cluster VictoriaMetrics + Grafana (Phase 2, Week 10) get added
  # alongside once k3s is up.

  # services.telegraf.enable = true;
  # services.victoriametrics.enable = true;
}
