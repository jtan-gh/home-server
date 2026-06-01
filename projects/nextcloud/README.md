# Nextcloud

Nextcloud, a file and photo management solution, is deployed via Helm in the `nextcloud` namespace. TLS is terminated at NGF using the wildcard cert-manager certificate. Nextcloud runs HTTP internally.

---

## Files

- `nextcloud-values.yaml` — Helm values (PostgreSQL, Redis, storage, probes, cronjob)
- `secrets/secrets.yaml` — credentials passed as a second values file (gitignored)
- `tank-pv.yaml` — PersistentVolume and PVC backed by ZFS tank
- `nextcloud-gateway.yaml` — HTTPRoute and ReferenceGrant

---

## Architecture

```
LAN device → Pi-hole DNS → 192.168.1.11 (NGF) → TLS terminated → HTTP → nextcloud:80
```

PostgreSQL and Redis are deployed as subcharts within the same Helm release. All user data is stored on the ZFS tank at `/tank/nextcloud-data`.

---

## DNS Setup

### Pi-hole

Add a local DNS record in the Pi-hole admin UI:

```
nextcloud.jtanprojects.com → 192.168.1.11
```

### Cloudflared (Optional)

Add to cloudflared ConfigMap and restart pod to expose app over wan:

```yaml
ingress:
  - hostname: nextcloud.jtanprojects.com
    service: http://nextcloud.nextcloud.svc.cluster.local:80
```

```bash
kubectl rollout restart deployment cloudflared-tunnel -n cloudflared
```

---

## Storage

| PVC | StorageClass | Mount | Purpose |
|-----|-------------|-------|---------|
| `nextcloud-data` | `tank` | `/var/www/html` | All Nextcloud files and user data on ZFS tank |

The `local-path` provisioner handles smaller PVCs for PostgreSQL and Redis automatically.

### ZFS tank permissions

Nextcloud does not create its data directory — you must create it and set permissions before applying the PV or installing. The PV uses `DirectoryOrCreate` which creates the folder if missing, but it will be owned by root, causing Nextcloud to fail on startup.

Do this before running `helm install`:

```bash
sudo mkdir -p /tank/nextcloud-data
sudo chown -R 33:33 /tank/nextcloud-data
```

### External storage (/tank/pics)

`/tank/pics` is mounted into the pod at `/mnt/pics` via `extraVolumes` in the values file. This makes the files physically available inside the container — but Nextcloud won't show them in the UI until you register the path as an external storage location after the pod is running. See [Exposing /tank/pics in the UI](#exposing-tankpics-in-the-ui) in the Post-Install section.

---

## Secrets

Credentials are stored in `secrets/secrets.yaml` and passed as a second values file during install. This file is gitignored. The key names must exactly match what the chart expects:

> **Postgres username must be "nextcloud"**. Using the wrong key here causes a silent install failure where PostgreSQL authentication fails and the setup wizard never completes.

---

## Install

### Prerequisites

```bash
helm repo add nextcloud https://nextcloud.github.io/helm/
helm repo update

kubectl apply -f ./secrets/secrets.yaml
```

### Fresh install

```bash
# 1. Wipe and prepare tank directory (skip if you already ran in "ZFS tank permissions" section)
sudo rm -rf /tank/nextcloud-data
sudo mkdir -p /tank/nextcloud-data
sudo chown -R 33:33 /tank/nextcloud-data

# 2. Apply PV/PVC
kubectl apply -f tank-pv.yaml

# 3. Install
helm install nextcloud nextcloud/nextcloud \
  -n nextcloud \
  --create-namespace \
  -f nextcloud-values.yaml

# 4. Watch pods — wait until nextcloud pod is Running before proceeding
kubectl get pods -n nextcloud -w
```

### Upgrade

```bash
helm upgrade nextcloud nextcloud/nextcloud \
  -n nextcloud \
  -f nextcloud-values.yaml
```

Note: `helm upgrade` does not restart StatefulSets (PostgreSQL, Redis) unless their spec changes. If you need them to pick up new config:

```bash
kubectl rollout restart statefulset nextcloud-postgresql -n nextcloud
kubectl rollout restart statefulset nextcloud-redis-master -n nextcloud
kubectl rollout restart statefulset nextcloud-redis-replicas -n nextcloud
```

### Gateway

```bash
kubectl apply -f nextcloud-gateway.yaml
```

---

## Full teardown

Use this when reinstalling from scratch. The `jq` command finds and deletes all PVs that were bound to the nextcloud namespace:

```bash
helm uninstall nextcloud -n nextcloud
kubectl delete pvc -n nextcloud --all
kubectl get pv -o json | jq -r '
  .items[]
  | select(.spec.claimRef.namespace=="nextcloud")
  | .metadata.name
' | xargs kubectl delete pv
```

---

## Post-Install

### ⚠️ First-time setup wizard

> **Known issue:** On first deploy, the Nextcloud web UI shows the setup wizard instead of the login page — even though credentials were passed via secrets. This is a known behavior of the community Helm chart. The entrypoint installs Nextcloud and creates the database schema correctly, but the trusted domain config isn't set yet, causing Nextcloud to fall back to the setup wizard.
>
> **Workaround:**
> 1. Complete the setup wizard with a new admin username (different from the one in secrets)
> 2. Log in and go to Users → delete the old auto-created admin via `occ`:
>    ```bash
>    kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- php occ user:list
>    kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- php occ user:delete <old-admin>
>    ```
> 3. Run the post-install commands below to set trusted domains and proxy config

### Exposing /tank/pics in the UI

The volume mount in `nextcloud-values.yaml` makes `/tank/pics` available inside the container at `/mnt/pics`. This is just infrastructure — Nextcloud's app layer still needs to be told to show it to users as a drive.

Two separate concerns:
- **Volume mount** (`extraVolumes` in values) — makes the path exist inside the container. Already done.
- **External storage registration** (`occ` commands below) — tells Nextcloud to show that path as a drive in the UI.

```bash
# Enable the external storage app
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- php occ app:enable files_external

# Register /mnt/pics as "Photos" visible to all users
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- php occ files_external:create \
  --config datadir=/mnt/pics \
  "Photos" \
  local \
  null::null

# Verify the mount is registered
kubectl exec -n nextcloud -it deployment/nextcloud -c nextcloud -- php occ files_external:list

# Verify the files are visible inside the container
kubectl exec -n nextcloud -it deployment/nextcloud -c nextcloud -- ls -la /mnt/pics

# Index all files so they appear in the UI
kubectl exec -n nextcloud -it deployment/nextcloud -c nextcloud -- php occ files:scan --all
```

### Pre-generate thumbnails

For large photo libraries, pre-generate all thumbnails in the background so browsing is instant. Install the preview generator app first:

```bash
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- php occ app:install previewgenerator
```

Then run generation in the background (avoids blocking the terminal):

```bash
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- bash -c "nohup php occ preview:generate-all > /tmp/preview.log 2>&1 &"
```

Monitor progress:

```bash
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- tail -f /tmp/preview.log
```

---

## Known Issues & Fixes

### Setup wizard shown on first deploy

See [First-time setup wizard](#️-first-time-setup-wizard) above. This is a known Helm chart limitation — complete the wizard manually and clean up the duplicate admin user.

### OOMKilled when browsing photos

**Cause:** Nextcloud generates thumbnails concurrently on first load. Each PHP process uses 100-200MB. Thousands of images exceed the memory limit quickly.

**Fix:** Increase memory limit and cap preview resolution in values, then pre-generate thumbnails:

```yaml
resources:
  requests:
    memory: 1Gi
    cpu: 500m
  limits:
    memory: 4Gi
    cpu: 2000m
nextcloud:
  phpConfigs:
    memory.ini: |
      memory_limit=512M
```

### `Configs` block in values causes crash on first deploy

**Cause:** The `configs` field in values mounts a ConfigMap into `/var/www/html/config/` which conflicts with the entrypoint trying to write `config.php` to the same directory during installation.

**Fix:** Do not use the `configs` block. Set all system config via `occ` commands after installation instead.

```yaml
  configs:
    proxy.config.php: |-
      <?php
      $CONFIG = array (
        ...
      );
```

### PostgreSQL password mismatch after reinstall

**Cause:** PostgreSQL PVC was not deleted during teardown so it retained old credentials. The new install uses different passwords and can't connect.

**Fix:** Always run the full teardown including `kubectl delete pvc -n nextcloud --all` and delete all PVs before reinstalling.

---

## Debugging Commands

```bash
# Check pod status
kubectl get pods -n nextcloud

# Check if installed
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- php occ status

# Check trusted domains
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- php occ config:system:get trusted_domains

# Check main logs
kubectl logs -n nextcloud -l app.kubernetes.io/name=nextcloud -c nextcloud --tail=50

# Check cron logs
kubectl logs -n nextcloud -l app.kubernetes.io/name=nextcloud -c nextcloud-cron --tail=20

# Test via NGF
curl -s -o /dev/null -w "%{http_code}" --resolve nextcloud.jtanprojects.com:443:192.168.1.11 https://nextcloud.jtanprojects.com/

curl -s -o /dev/null -w "%{http_code}" --resolve nextcloud.jtanprojects.com:443:192.168.1.11 https://nextcloud.jtanprojects.com/login

# Test bypassing NGF (direct pod)
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- curl -s -o /dev/null -w "%{http_code}" http://localhost/status.php

# Check thumbnail generation progress
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- tail -f /tmp/preview.log

# Check thumbnails generated
kubectl exec -n nextcloud deployment/nextcloud -c nextcloud -- cat /tmp/preview.log
```
