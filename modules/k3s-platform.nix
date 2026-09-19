{ ... }:

{
  services.k3s = {
    enable = true;
    role = "server";

    clusterInit = true;

    extraFlags = toString [
      "--cluster-cidr=10.42.0.0/16"
      "--service-cidr=10.43.0.0/16"

      "--disable=traefik"

      "--kubelet-arg=system-reserved=cpu=250m,memory=512Mi"
      "--kubelet-arg=kube-reserved=cpu=250m,memory=512Mi"
      "--kubelet-arg=eviction-hard=memory.available<512Mi,nodefs.available<10%"
      "--kubelet-arg=eviction-soft=memory.available<1Gi,nodefs.available<15%"
      "--kubelet-arg=eviction-soft-grace-period=memory.available=1m,nodefs.available=1m"
    ];
  };
}
