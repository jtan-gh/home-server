# OpenCloud

OpenCloud is deployed in the `opencloud` namespace and served via NGINX Gateway Fabric. TLS is terminated at the gateway using a cert-manager wildcard certificate. OpenCloud runs in HTTP mode internally.

## Files

- `opencloud.yaml` — Deployment, Service, HTTPRoute
- `configmap.yaml` — Non-sensitive configuration
- `coredns.yaml` - rewrite for internal DNS resolution
- `secret.yaml` — Admin password (gitignored)
- `pv.yaml` — PersistentVolumeClaims and pvc for configs and ZFS tank storage

---

## Architecture

```
LAN/WAN → 192.168.1.11:443 (NGF) → TLS terminated → HTTP → opencloud:9200
```

OpenCloud does not handle TLS itself. The wildcard cert (`*.jtanprojects.com`) is managed entirely by cert-manager and presented by NGF. OpenCloud only needs to know its public URL is HTTPS — it serves plain HTTP internally.

---

## DNS Setup

### Local (Pi-hole)

Add a local DNS record in the Pi-hole admin UI:

```
opencloud.jtanprojects.com → 192.168.1.11
```

**Pi-hole admin → Local DNS → DNS Records**

This makes `https://opencloud.jtanprojects.com` resolve to NGF for all LAN devices using Pi-hole as their DNS server. Devices must have Pi-hole (`192.168.1.20`) set as their DNS server for this to work.

### Public (WAN)

Public traffic is handled by cloudflared. The cloudflared pod connects directly to the OpenCloud service inside the cluster — no public DNS record needed for `opencloud.jtanprojects.com`.

Cloudflared config should point to the internal service:

```yaml
ingress:
  - hostname: opencloud.jtanprojects.com
    service: http://opencloud.opencloud.svc.cluster.local:9200
  - service: http_status:404
```

### Internal pod DNS (OIDC)

OpenCloud internally calls its own `OC_URL` to verify OIDC tokens. Inside the cluster, `opencloud.jtanprojects.com` doesn't resolve unless CoreDNS is told about it.

A CoreDNS rewrite maps the domain to the NGF service name (stable, no hardcoded IPs):

```yaml
# coredns-custom.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  opencloud.override: |
    rewrite name opencloud.jtanprojects.com nginx-gateway-nginx.gateway-system.svc.cluster.local
```

```bash
kubectl apply -f coredns-custom.yaml
kubectl rollout restart deployment coredns -n kube-system
```

This only affects DNS inside the cluster. Pi-hole, Cloudflare, and everything outside are untouched.

---

## Configuration

### ConfigMap (`opencloud-config`)

```yaml
OC_URL: "https://opencloud.jtanprojects.com"   # must be https even though pod serves HTTP
IDM_URL: "https://opencloud.jtanprojects.com"
IDM_ADMIN_USERNAME: "admin"
OC_INSECURE: "true"                             # allows internal OIDC calls over HTTP
PROXY_SKIP_VERIFY_TLS: "true"
```

### Secret (`opencloud-secret`)

```yaml
IDM_ADMIN_PASSWORD: "<admin-password>"
```

Keep this file out of git. Recreate with:

```bash
kubectl create secret generic opencloud-secret \
  --namespace opencloud \
  --from-literal=IDM_ADMIN_PASSWORD='your-password'
```

### Deployment env vars

Set directly in the deployment (not ConfigMap) since they are tightly coupled to how the pod runs:

```yaml
env:
  - name: PROXY_TLS
    value: "false"        # OpenCloud serves HTTP, NGF handles TLS
  - name: OC_INSECURE
    value: "true"
  - name: PROXY_HTTP_ADDR
    value: "0.0.0.0:9200"
```

---

## Storage

| PVC | StorageClass | Mount | Purpose |
|-----|-------------|-------|---------|
| `opencloud-config` | `local-path` | `/etc/opencloud` | Generated config file |
| `opencloud-tank` | `tank` | `/var/lib/opencloud` | User data on ZFS tank |

The ZFS tank (`/tank` on host) is used as OpenCloud's primary data directory. The `tank` storageClass uses a manual hostPath PV pointing to `/tank`.

### Permissions

OpenCloud runs as UID 1000. The tank must be owned by UID 1000:

```bash
sudo chown -R 1000:1000 /tank
```

`local-user` is also GID 1000, so files created on the host are accessible to OpenCloud and vice versa.

---

## Init Container

The deployment in `opencloud.yaml` includes an initContainer that runs before the main OpenCloud container starts. You don't run this manually — it executes automatically every time the pod starts.

Its command is:

```bash
[ -f /etc/opencloud/opencloud.yaml ] && exit 0
opencloud init
```

- **First deploy:** the config file doesn't exist yet, so `opencloud init` runs and generates `/etc/opencloud/opencloud.yaml` with all the secrets and settings OpenCloud needs.
- **Every redeploy after:** the config file already exists, so the initContainer exits immediately and skips init — preserving your existing config and passwords.

Without this check, `opencloud init` would overwrite the config on every pod restart, regenerating new secrets and breaking the running instance. Just apply `opencloud.yaml` as normal — the initContainer handles the rest.

### Force re-initialisation
> **⚠️ WARNING — read this before wiping the config.**
>
> `opencloud init` only generates `opencloud.yaml`. It does **not** delete files in `storage/users/`. However, re-init regenerates all cryptographic secrets (JWT secret, LDAP passwords, service account keys). These secrets are tied to your user accounts and spaces — regenerating them means new user UUIDs are created on next startup, leaving your existing files at their old UUID paths orphaned and inaccessible through OpenCloud. **The files themselves survive on disk but become effectively unreachable through the UI.**
>
> Only force re-init on a **fresh install with no uploaded data**, or if you are fully deleting all data and starting over. Changing `OC_URL` alone does not require re-init — just update the ConfigMap, restart the pod, and the env var takes effect.
 
If you are certain you want to start fresh:

```bash
kubectl scale deployment opencloud -n opencloud --replicas=0

kubectl run -it --rm wipe --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"config","persistentVolumeClaim":{"claimName":"opencloud-config"}}],"containers":[{"name":"wipe","image":"busybox","command":["sh","-c","rm -f /etc/opencloud/opencloud.yaml && echo done"],"volumeMounts":[{"name":"config","mountPath":"/etc/opencloud"}]}]}}' \
  -n opencloud

kubectl scale deployment opencloud -n opencloud --replicas=1
kubectl logs -n opencloud -l app=opencloud -c init -f
```

---

## Deployment

### Fresh install

```bash
kubectl create namespace opencloud
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f pv.yaml
kubectl apply -f tank-pv.yaml
kubectl apply -f opencloud.yaml
kubectl logs -n opencloud -l app=opencloud -c init -f
```

### Teardown

```bash
kubectl delete namespace opencloud
kubectl delete pv opencloud-tank-pv
```

Note: `local-path` PVCs are deleted automatically with the namespace. The tank PV uses `Retain` policy — deleting the PV object does **not** delete files on `/tank`.

---

## Known Issues & Fixes

### Missing or invalid config after redeployment

**Cause:** The init container found an existing `opencloud.yaml` (from a previous run on the same PVC) and skipped init. The old config had wrong `OC_URL` values.

**Fix:** Force re-initialisation by deleting the config file as shown above. Always verify the ConfigMap has the correct `OC_URL` before scaling back up:

```bash
kubectl get configmap opencloud-config -n opencloud -o yaml | grep OC_URL
```

### OIDC token verification failing (login broken)

**Cause:** OpenCloud internally calls `https://opencloud.jtanprojects.com` to verify OIDC tokens. Without the CoreDNS rewrite, this domain doesn't resolve inside the cluster, so all logins fail.

**Fix:** Apply the CoreDNS custom ConfigMap described in the DNS section above.

### Pod crashes with permission denied on /tank

**Symptom:** `CrashLoopBackOff` with error `unfit storage '/tank': could not create file in root path: permission denied`

**Fix:**

```bash
sudo chown -R 1000:1000 /tank
kubectl rollout restart deployment opencloud -n opencloud
```

### PV stuck in Released state

**Symptom:** `opencloud-tank` PVC stays `Pending` because the PV shows `Released` from a previous binding.

**Fix:**

```bash
kubectl patch pv opencloud-tank-pv -p '{"spec":{"claimRef":null}}'
```

---

## Debugging Commands

```bash
# Check pod status
kubectl get pods -n opencloud

# Check init logs
kubectl logs -n opencloud -l app=opencloud -c init

# Check main container logs
kubectl logs -n opencloud -l app=opencloud -c opencloud

# Check env vars loaded into container
kubectl exec -n opencloud deploy/opencloud -- env | grep -E "OC_|IDM_|PROXY_"

# Check generated config
kubectl exec -n opencloud deploy/opencloud -- cat /etc/opencloud/opencloud.yaml

# Test internally
kubectl exec -n opencloud deploy/opencloud -- wget -qO- http://localhost:9200/health

# Test from host via NGF
curl -v --resolve opencloud.jtanprojects.com:443:192.168.1.11 https://opencloud.jtanprojects.com
```
