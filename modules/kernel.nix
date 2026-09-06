{ config, lib, pkgs, ... }:
{
  boot.kernelModules = [
    "overlay"
    "br_netfilter"
    "nf_tables"
    "ip_tables"
    "tcp_bbr"
    # MPLS forwarding for the Containerlab fabric's Week 5 VPNv4 work
    "mpls_router"
    "mpls_iptunnel"
  ];
  boot.kernel.sysctl = {
    # bridged traffic through iptables — required by k3s/Calico/Flannel
    "net.bridge.bridge-nf-call-iptables"  = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward"                 = 1;
    # TCP BBR congestion control
    "net.core.default_qdisc"          = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
    # Kubernetes / Elasticsearch-style workloads want this raised
    "vm.max_map_count" = 262144;
    # prefer reclaiming page cache over swapping on a box running containers
    "vm.swappiness" = 10;
    # containerd/k3s/inotify-heavy tooling (fswatch, VS Code remote, etc.)
    "fs.inotify.max_user_watches"   = 524288;
    "fs.inotify.max_user_instances" = 512;
    # MPLS label table + input — required for the fabric's VPNv4/LDP forwarding
    "net.mpls.platform_labels" = 100000;
    "net.mpls.conf.all.input"  = 1;
  };
}

