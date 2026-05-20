# Gateway — NGINX Gateway Fabric (NGF)

This directory contains configuration for NGINX Gateway Fabric (NGF). This is an alternative entry point to cloudflared. Very useful for split-dns or local traffic management

## Files

- `gateway.yaml` — Gateway resource defining HTTP, HTTPS, and TLS passthrough listeners
- `nginx-gateway-values.yaml` — Helm values for NGF installation

---

## Installation

### Why OCI and not nginx-stable
 
NGINX publishes two completely separate products under similar names:
 
| Product | Helm source | Based on |
|---------|------------|----------|
| **NGINX Ingress Controller** | `nginx-stable` Helm repo | older `Ingress` API |
| **NGINX Gateway Fabric** | OCI registry (`ghcr.io`) | modern Gateway API |
 
These are not the same thing and are not interchangeable. NGF is the newer implementation built around the Kubernetes Gateway API (`HTTPRoute`, `TLSRoute`, `GatewayClass`, etc.). The `nginx-stable` Helm repo only contains NGINX Ingress Controller charts — NGF is not in it.
 
If you try to upgrade NGF using `nginx-stable/nginx-gateway-fabric`, Helm will throw `repo nginx-stable not found` because the install never came from there.
 
### Install
 
```bash
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --namespace nginx-gateway \
  --values nginx-gateway-values.yaml
```
 
### Upgrade
 
Always use the same OCI source as the install:
 
```bash
helm upgrade ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --namespace nginx-gateway \
  --values nginx-gateway-values.yaml
```
 
---

## Architecture

NGF runs as two components:

- **Control plane** (`ngf-nginx-gateway-fabric`) in the `nginx-gateway` namespace — manages configuration
- **Data plane** (`nginx-gateway-nginx`) in `gateway-system` — handles actual traffic

The data plane Service (`nginx-gateway-nginx`) is a LoadBalancer assigned `192.168.1.11` by MetalLB. This is the IP all traffic flows through.

```
LAN device → 192.168.1.11 (MetalLB) → nginx-gateway-nginx pod → backend service
```

---

## Listeners

For this gateway we have three listeners:

| Name | Port | Protocol | Purpose |
|------|------|----------|---------|
| `http` | 80 | HTTP | Redirects to HTTPS |
| `https` | 443 | HTTPS | TLS termination using wildcard cert |
| `passthrough` | 8443 | TLS | TLS passthrough for apps managing their own certs |

The wildcard cert (`wildcard-tls` in `gateway-system`) is managed by cert-manager and covers `*.jtanprojects.com`.

---

## Routing

Apps attach to the gateway via `HTTPRoute` (for HTTPS termination) or `TLSRoute` (for passthrough):
view /test folder for examples

### Cross-namespace routing

When an `HTTPRoute` is in a different namespace than the Gateway, a `ReferenceGrant` is required in the app's namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway
  namespace: my-namespace   ##namespace the app is in
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: gateway-system
  to:
    - group: ""
      kind: Service
```

Without this, NGF silently fails to resolve the backend even if the route shows `Accepted: True`.

---

## TLS Passthrough (port 8443)

For apps that manage their own TLS certificates, use a `TLSRoute` against the `passthrough` listener. NGF reads the SNI from the ClientHello without decrypting and forwards raw TCP to the backend.

The `TLSRoute` CRD is part of the Gateway API experimental channel. Install it separately:

```bash
# Remove the safe-upgrades policy first (blocks experimental CRDs on top of standard)
kubectl delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml
```

---

## Known Issues & Fixes

### Port 8443 not appearing in Service

**Symptom:** `kubectl get svc -n gateway-system` only shows ports 80 and 443, not 8443.

**Cause:** NGF dynamically adds Service ports based on Gateway listeners. The Service is in `gateway-system`, not `nginx-gateway`. Always check the right namespace:

```bash
kubectl get svc -n gateway-system
```

**Fix:** Add the listener to the Gateway resource. NGF automatically syncs the Service ports.

---

### Pod-to-pod communication failing (Host is unreachable)

**Symptom:** nginx pod gets `connect() failed (113: Host is unreachable)` when trying to reach backend pods by IP. ClusterIP works but pod IPs don't.

**Root cause:** firewalld was blocking traffic in the kernel's `FORWARD` chain. When pods communicate across the `cni0` bridge, Linux treats it as forwarded traffic — the same chain that governs traffic between network interfaces on a router. firewalld's default policy rejects anything not explicitly trusted.

**Why ClusterIP worked:** kube-proxy DNAT for ClusterIP takes a different path through the kernel's NAT stack that firewalld's rules permitted. Direct pod IP connections hit the FORWARD chain and were rejected.

**Fix:** Add the pod and service CIDRs to firewalld's trusted zone:

```bash
sudo firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.43.0.0/16 --permanent
sudo firewall-cmd --zone=trusted --add-interface=cni0 --permanent
sudo firewall-cmd --reload
```

---

### External LAN traffic can't reach NGF on port 443

**Symptom:** Devices on the LAN can reach port 80 (get nginx 404) but HTTPS connections to `192.168.1.11` fail. `Test-NetConnection -Port 443` succeeds (TCP connects) but the browser gets "secure connection failed".

**Root cause:** MetalLB Layer 2 mode makes the host respond to ARP for `192.168.1.11`. Packets arrive on the LAN interface (`wlo1`) in the `public` firewalld zone. Without masquerade enabled, response packets from pods go back with source IP `10.42.x.x` which LAN clients have no route to.

**Fix:**

```bash
sudo firewall-cmd --zone=public --add-masquerade --permanent
sudo firewall-cmd --zone=public --add-forward --permanent
sudo firewall-cmd --zone=public --add-port=80/tcp --permanent
sudo firewall-cmd --zone=public --add-port=443/tcp --permanent
sudo firewall-cmd --reload
```

---

## Debugging Commands

```bash
# Check Gateway listener status
kubectl describe gateway nginx-gateway -n gateway-system

# Check data plane Service ports
kubectl get svc -n gateway-system

# Check nginx generated config (stream block, upstreams, etc.)
kubectl exec -n gateway-system <nginx-pod> -- nginx -T 2>/dev/null

# Check nginx error logs
kubectl logs -n gateway-system <nginx-pod>

# Check NGF controller logs
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric

# Check HTTPRoute status
kubectl describe httproute <name> -n <namespace>
```
