# home-server

A self-hosted Kubernetes home server running on k3s (Debian), with local network access via Pi-hole split DNS and public access via Cloudflare Tunnels.

---

## Stack Overview

| Component | Purpose |
|-----------|---------|
| **k3s** | Lightweight Kubernetes distribution |
| **MetalLB** | Assigns real LAN IP addresses to LoadBalancer services |
| **NGINX Gateway Fabric (NGF)** | Handles all ingress — TLS termination, routing, passthrough |
| **cert-manager** | Automatically issues and renews TLS certificates via Let's Encrypt |
| **cloudflared** | Exposes services to the public internet via Cloudflare Tunnels |
| **Pi-hole** | Local DNS server — resolves internal domains on the LAN |

---

## How Traffic Flows

There are two separate paths depending on where the request originates.

### WAN (public internet)

```
User → Cloudflare edge → cloudflared pod (inside cluster) → internal service
```

Cloudflare holds the public DNS records. Traffic never touches your router or public IP — it flows through an outbound encrypted tunnel that the `cloudflared` pod maintains. No port forwarding required.

### LAN (home network)

```
Device → Pi-hole DNS → 192.168.1.11 (MetalLB) → NGF → internal service
```

Pi-hole resolves internal domains (e.g. `app.jtanprojects.com`) to `192.168.1.11`, the MetalLB IP assigned to NGF. NGF terminates TLS using a wildcard cert from cert-manager and routes to the correct backend service.

---

## Component Details

### k3s

Lightweight Kubernetes — runs the entire cluster on a single Debian node. Ships with Flannel (CNI), CoreDNS, and a local-path storage provisioner out of the box.

### MetalLB

Kubernetes has no native way to assign real IP addresses to `LoadBalancer` services on bare metal. MetalLB fills this gap using Layer 2 mode — it responds to ARP requests for assigned IPs on the LAN, making those IPs reachable from any device on the network.

NGF is assigned `192.168.1.11` by MetalLB. This is the single entry point for all LAN HTTPS traffic.

### NGINX Gateway Fabric (NGF)

NGF is the cluster's ingress controller, built on the Kubernetes Gateway API (`HTTPRoute`, `TLSRoute`, `GatewayClass`). It is different from NGINX Ingress Controller — see `gateway/README.md` for the distinction.

NGF runs as two components:
- Control plane in `nginx-gateway` namespace
- Data plane (`nginx-gateway-nginx`) in `gateway-system` namespace — this is what receives traffic

Three listeners are configured:

| Port | Protocol | Purpose |
|------|----------|---------|
| 80 | HTTP | Redirects to HTTPS |
| 443 | HTTPS | TLS termination using wildcard cert |
| 8443 | TLS | Passthrough for apps managing their own certs |

### cert-manager

Automatically issues and renews TLS certificates from Let's Encrypt using DNS-01 challenge (via Cloudflare DNS API). A single wildcard certificate covers `*.jtanprojects.com` and is stored in the `gateway-system` namespace where NGF can access it.

Certificates never expire silently — cert-manager renews them automatically ~30 days before expiry.

### cloudflared

Runs as a pod inside the cluster. It maintains a persistent outbound tunnel to Cloudflare's edge, receiving public traffic without any open inbound ports on your router.

Routes are configured via a ConfigMap that maps public hostnames to internal Kubernetes service URLs:

```yaml
ingress:
  - hostname: app.jtanprojects.com
    service: http://app-svc.namespace.svc.cluster.local:80
```

See `cloudflared/README.md` for setup instructions.

### Pi-hole

Local DNS server running at `192.168.1.20`. All LAN devices should use this as their DNS server.

Pi-hole serves two purposes:
1. **Ad blocking** — blocks ads network-wide
2. **Split DNS** — resolves internal domains to `192.168.1.11` (NGF) instead of public Cloudflare IPs, keeping LAN traffic local

For each app you want accessible on the LAN, add a record:
```
app.jtanprojects.com → 192.168.1.11
```

---

## Prerequisites

- [git](https://git-scm.com/install/linux)
- [k3s](https://docs.k3s.io/quick-start)
- [Helm](https://helm.sh/docs/intro/install/)
- A Cloudflare account with your domain managed there
- Two drives available for ZFS mirroring (optional but recommended)

---

## Fresh Install Order

When setting up from scratch, apply resources in this order:

```bash
# 1. Install k3s
curl -sfL https://get.k3s.io | sh -

# 2. Install MetalLB and configure IP pool
# 3. Install cert-manager
# 4. Install NGF (see gateway/README.md)
# 5. Apply Gateway resource
kubectl apply -f gateway/gateway.yaml

# 6. Deploy cloudflared (see cloudflare/README.md)
cd cloudflared && ./setup

# 7. Deploy apps in projects/
```
