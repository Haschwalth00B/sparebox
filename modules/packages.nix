{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # ── base (original) ──────────────────────────────────────────────
    git
    vim
    curl
    wget
    htop
    fastfetch
    btop
    unzip

    # ── networking / SD-WAN / routing ──────────────────────────────
    bird2
    frr
    wireguard-tools
    strongswan
    containerlab

    # ── kubernetes ──────────────────────────────────────────────────
    kubectl
    k9s
    kubernetes-helm
    fluxcd
    kustomize
    kubectx           # also provides `kubens`

    # ── github / git ──────────────────────────────────────────────
    gh
    git-lfs

    # ── general dev tools ────────────────────────────────────────
    python3
    jq
    yq-go
    ripgrep
    fd
    tree
    tmux
    screen
    bat
    eza
    fzf

    # ── observability binaries (also deployable inside k8s later) ─
    prometheus
    grafana
    victoriametrics

    # ── benchmarking (iperf3 lives in modules/monitoring.nix) ─────
    stress-ng
    fio
    hyperfine

    # ── secrets / crypto ──────────────────────────────────────────
    age
    sops
    gnupg

    # ── nix tooling ───────────────────────────────────────────────
    nix-tree
    nix-output-monitor
    nixpkgs-fmt
    statix
    deadnix
  ];
}

