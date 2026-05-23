# cloudflared

Runs as a pod inside the cluster, maintaining a persistent outbound tunnel to Cloudflare's edge. Public traffic enters the cluster through this tunnel without requiring any open inbound ports or port forwarding on your router.

---

## How It Works

```
User → Cloudflare DNS (CNAME → tunnel ID) → Cloudflare edge → cloudflared pod → internal service
```

1. User visits `app.jtanprojects.com`
2. Cloudflare DNS has a CNAME pointing to `<tunnel-id>.cfargotunnel.com`
3. Cloudflare's edge forwards the request through the persistent encrypted tunnel to the `cloudflared` pod
4. The pod reads its ConfigMap and matches the hostname against ingress rules
5. It proxies the request to the internal Kubernetes service via cluster DNS
6. The response travels back through the tunnel to the user

No public IP, no open ports, no port forwarding required.

---

## Files

- `configmap.yaml` — tunnel config mapping hostnames to internal services
- `setup` — first-time setup script that injects tunnel credentials into the cluster

---

## First-Time Setup

### 1. Install cloudflared CLI

Follow only Steps 1 and 2 (create tunnel, do not configure routing yet):
https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/

After this you should have a credentials file at:
```bash
ls ~/.cloudflared
# {tunnel-uuid}.json  config.yml
```

### 2. Run the setup script

```bash
./setup
```

The script reads your tunnel UUID and credentials and creates the necessary Kubernetes Secret and ConfigMap.

Verify the UUID was injected correctly:
```bash
cat cloudflared/configmap.yaml | grep uuid
```

---

## Adding a New Service

Edit `configmap.yaml` and add a new ingress rule:

```yaml
ingress:
  - hostname: newapp.jtanprojects.com
    service: http://newapp-svc.namespace.svc.cluster.local:80
  - service: http_status:404   # catch-all — always keep this last
```

Then apply:
```bash
kubectl apply -f configmap.yaml
```

The cloudflared pod picks up the new config automatically.

> **Note:** cloudflared bypasses NGF entirely — it connects directly to internal service URLs using Kubernetes DNS. You do not need an HTTPRoute or Pi-hole record for services exposed only via cloudflared.

---

## Reissuing Tunnel Credentials

If you need to regenerate credentials for an existing tunnel:
https://community.cloudflare.com/t/how-to-recover-or-reissue-credentials-json-for-existing-tunnel/802258
