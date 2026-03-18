# TLS Re-encryption with Envoy Gateway
### client → HTTPS → gateway → HTTPS → nginx-service

## Architecture

```
Client (browser / curl)
  │
  │  HTTPS — api.jtanprojects.com
  │  cert:  api-public-tls (Let's Encrypt)
  ▼
Envoy Gateway
  │
  │  CoreDNS rewrites echo.internal.jtanprojects.com
  │                 → echo-service.echo.svc.cluster.local
  │
  │  HTTPS — echo.internal.jtanprojects.com
  │  cert:  internal-wildcard-tls (Let's Encrypt, *.internal.jtanprojects.com)
  ▼
nginx Service (echo namespace)
```

## Files

| File | Purpose |
|------|---------|
| `cert-manager/` | ClusterIssuer using Let's Encrypt DNS challenge via Cloudflare |
| `secrets.yaml` | Cloudflare API token Secret used by cert-manager |
| `gateway/` | Envoy Gateway install + GatewayClass + Gateway resource |
| `internal-tls/` | Certificate resources + BackendTLSPolicy for each internal service |
| `nginx-https-deployment/` | nginx Deployment + Service serving HTTPS on 8443 |
| `configmap.yaml` | CoreDNS rewrite rule — routes internal domain to cluster service |

---

## Prerequisites

- Kubernetes cluster (tested on kubeadm)
- `kubectl` and `helm` installed
- Cloudflare API token with DNS edit permissions for `jtanprojects.com`

---

## Creating the Cloudflare API Token

You'll do this once. The token allows cert-manager to create and delete DNS TXT records
on your behalf to complete the Let's Encrypt DNS-01 challenge.

### 1. Log in to Cloudflare
Go to [dash.cloudflare.com](https://dash.cloudflare.com) and sign in.

### 2. Open API Tokens
Click your **profile icon** in the top-right corner → **My Profile** → select
**API Tokens** from the left sidebar.

### 3. Create a new token
Click **Create Token** → then click **Create Custom Token** at the bottom
(do not use a template).

### 4. Configure the token

**Token name:** something memorable like `cert-manager-letsencrypt`

**Permissions** — add these two rows exactly:

| Category | Subcategory | Access |
|----------|-------------|--------|
| Zone | Zone | Read |
| Zone | DNS | Edit |

To add each row: click **+ Add more** and select from the dropdowns.

**Zone Resources:**

Set to:
```
Include → All zones
```

This is required because cert-manager queries Cloudflare to look up which zone
owns the domain before it can create the TXT record. Scoping to a specific zone
can cause a `requires permission to list zones` error.

**IP Address Filtering:** leave empty (optional, but you could lock it to your
server's IP for extra security).

**TTL:** leave as no expiry, or set a long expiry (1 year+). If the token expires,
cert-manager will silently fail to renew certificates.

### 5. Create and copy the token
Click **Continue to Summary** → review the permissions → click **Create Token**.

**Copy the token immediately** — Cloudflare only shows it once.

### 6. Verify the token works
```bash
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer <YOUR_TOKEN>" \
  -H "Content-Type: application/json"

# Expected response:
# {"result":{"status":"active"},"success":true,...}
```

### 7. Store the token in secrets.yaml
The token is stored as a Kubernetes Secret in the `cert-manager` namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: <YOUR_TOKEN_HERE>   # paste the token from step 5
```

> **Never commit secrets.yaml to git.** Add it to `.gitignore`.
> If you use a GitOps tool like Flux or ArgoCD, use Sealed Secrets or
> an external secrets manager instead.

---

## Setup

### 1. Install cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml
kubectl rollout status deployment -n cert-manager --timeout=120s
```

Apply the Cloudflare API token and ClusterIssuer:

```bash
# Token is stored in secrets.yaml — apply before the ClusterIssuer
kubectl apply -f secrets.yaml
kubectl apply -f cert-manager/
```

Verify the issuer is ready:

```bash
kubectl get clusterissuer letsencrypt-dns
# READY should be True
```

### 2. Install Envoy Gateway

> **Important:** do not install Gateway API CRDs separately. Always use the CRDs
> bundled with Envoy Gateway to avoid version mismatches that break BackendTLSPolicy.

```bash
# Install Gateway API CRDs bundled with Envoy Gateway
helm template eg oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.6.1 \
  --set crds.gatewayAPI.enabled=true \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

# Install Envoy Gateway
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.1 \
  -n envoy-gateway-system \
  --create-namespace

kubectl rollout status deployment/envoy-gateway \
  -n envoy-gateway-system --timeout=90s
```

Verify BackendTLSPolicy is being watched (not skipped):

```bash
kubectl logs -n envoy-gateway-system deployment/envoy-gateway --tail=50 \
  | grep -i backendtls
# Should show: Starting EventSource ... BackendTLSPolicy
```

Apply the Gateway resources:

```bash
kubectl apply -f gateway/
```

### 3. Apply CoreDNS rewrite

This rewrite is required so Envoy can resolve `echo.internal.jtanprojects.com`
to the internal service IP rather than attempting an external DNS lookup.
See [Why CoreDNS rewrite is needed](#why-coredns-rewrite-is-needed) for details.

```bash
kubectl apply -f configmap.yaml
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=60s
```

Verify the rewrite works from inside the cluster:

```bash
kubectl run dns-test --rm -it --image=busybox -- \
  nslookup echo.internal.jtanprojects.com
# Should resolve to the ClusterIP of echo-service.echo.svc.cluster.local
```

### 4. Deploy nginx

```bash
kubectl apply -f nginx-https-deployment/
kubectl rollout status deployment -n echo --timeout=60s
```

### 5. Apply internal-tls

`internal-tls/` contains both the `Certificate` resources and the `BackendTLSPolicy`.
They are kept together because the policy depends directly on the cert — if you need
to add another service, duplicate this pattern (see [Adding a new service](#adding-a-new-service)).

```bash
kubectl apply -f internal-tls/
```

Wait for certificates to be issued (DNS challenge typically takes 1-2 minutes):

```bash
kubectl get certificate -n echo -w
# Both api-public-tls and internal-wildcard-tls should reach READY = True
```

Verify the BackendTLSPolicy is accepted:

```bash
kubectl describe backendtlspolicy echo-backend-tls -n echo
# Look for: Accepted: True
```

---

## Verification

The test below bypasses DNS and connects directly to the NodePort, so you can verify
the full TLS stack without opening firewall port 443 or configuring external DNS.
`--resolve` overrides DNS locally, and `-k` skips cert trust (Let's Encrypt is valid,
but this avoids needing the CA on your test machine).

```bash
# Replace 32309 with your actual NodePort and 192.168.1.78 with your node IP
curl -k --resolve api.jtanprojects.com:32309:192.168.1.78 \
  https://api.jtanprojects.com:32309
```

To also verify the backend TLS leg (not just the frontend), add `-v` and look for
two distinct TLS handshakes — one for the client connection and one in the Envoy logs:

```bash
# Verbose output — confirms frontend cert is api.jtanprojects.com
curl -kv --resolve api.jtanprojects.com:32309:192.168.1.78 \
  https://api.jtanprojects.com:32309 2>&1 | grep -E "subject|issuer|SSL|HTTP"

# Confirm Envoy is making a TLS connection to the backend (not plain HTTP)
kubectl logs -n envoy-gateway-system \
  $(kubectl get pod -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=eg \
    -o jsonpath='{.items[0].metadata.name}') \
  | grep -i "tls\|ssl" | tail -20
```

---

## Adding a new service

Because the wildcard cert `*.internal.jtanprojects.com` covers all subdomains,
new services **do not need a new Certificate**. The same `internal-wildcard-tls`
secret can be reused.

For each new service you need:

**1. CoreDNS rewrite** — add a new `rewrite` line to `configmap.yaml`:
```yaml
rewrite name myservice.internal.jtanprojects.com myservice-svc.mynamespace.svc.cluster.local
```
Then restart CoreDNS:
```bash
kubectl apply -f configmap.yaml
kubectl rollout restart deployment/coredns -n kube-system
```

**2. BackendTLSPolicy** — create a new file (e.g. `internal-tls/myservice-tls.yaml`):
```yaml
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata:
  name: myservice-backend-tls
  namespace: mynamespace
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: myservice-svc
  validation:
    caCertificateRefs:
      - group: ""
        kind: Secret
        name: internal-wildcard-tls   # reuse the existing wildcard cert
        namespace: echo               # namespace where the Secret lives
    hostname: myservice.internal.jtanprojects.com
```

**3. HTTPRoute** — add a route rule in `gateway/` pointing to your new service.

That's it — no new Certificate or ClusterIssuer needed.

---

## Troubleshooting

### 502 Bad Gateway

The backend TLS handshake is failing. Check:

```bash
# 1. Confirm BackendTLSPolicy is accepted
kubectl describe backendtlspolicy echo-backend-tls -n echo

# 2. Confirm the wildcard cert covers echo.internal.jtanprojects.com
kubectl get secret internal-wildcard-tls -n echo \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -text | grep -A2 "Subject Alternative"

# 3. Confirm CoreDNS rewrite is resolving correctly
kubectl run dns-test --rm -it --image=busybox -- \
  nslookup echo.internal.jtanprojects.com
```

### Certificate stuck in Pending

The DNS-01 challenge is not completing:

```bash
kubectl describe certificaterequest -n echo
kubectl describe challenge -n echo
# Look for Cloudflare API errors or DNS propagation delays
```

### BackendTLSPolicy not accepted

Envoy Gateway may have started before the CRD was installed. Restart it:

```bash
kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
kubectl apply -f internal-tls/
kubectl describe backendtlspolicy echo-backend-tls -n echo
```

### CoreDNS rewrite not taking effect

```bash
kubectl get configmap coredns -n kube-system -o yaml | grep rewrite
kubectl rollout restart deployment/coredns -n kube-system
```

---

## Why CoreDNS rewrite is needed

`BackendTLSPolicy` requires a `hostname` that matches the SAN on the backend cert.
The backend cert is a wildcard `*.internal.jtanprojects.com`, so the hostname must be
something like `echo.internal.jtanprojects.com`.

When Envoy opens a connection to the backend, it resolves this hostname via cluster DNS.
Without the rewrite, `echo.internal.jtanprojects.com` has no internal DNS record and the
lookup either fails or routes externally to the public internet.

The CoreDNS rewrite transparently maps:
```
echo.internal.jtanprojects.com → echo-service.echo.svc.cluster.local
```

Envoy resolves to the correct ClusterIP, while still sending
`echo.internal.jtanprojects.com` as the TLS SNI — which matches the wildcard cert.