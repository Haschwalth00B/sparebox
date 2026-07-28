FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y strongswan iproute2 iputils-ping && rm -rf /var/lib/apt/lists/*
CMD ["/usr/sbin/ipsec", "start", "--nofork"]
