# Normalize a single "ip route get" result to a canonical fabric route.
# Print nothing for management/default routes (notably eth0), missing gateways,
# or interfaces outside the Containerlab fabric.
{
  gateway = ""
  device = ""

  for (i = 1; i <= NF; i++) {
    if ($i == "via" && i < NF)
      gateway = $(i + 1)
    if ($i == "dev" && i < NF)
      device = $(i + 1)
  }

  if (gateway ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
      device ~ /^eth[123]$/)
    printf "via %s dev %s\n", gateway, device
}