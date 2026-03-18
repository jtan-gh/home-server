# OpenCloud on Kubernetes – Deployment Guide
This guide covers deploying OpenCloud on a single-node Kubernetes cluster (k3s) using hostPath PersistentVolumes. All data is stored under /opencloud on the host. The setup includes automatic certificate generation, initialisation, and the main OpenCloud server.

## Opencloud + cloudflare
### Prerequisites
- Kubernetes cluster (k3s recommended) with kubectl configured.
- A node with at least 4GB RAM and 20GB free disk space.
- Basic understanding of kubectl and YAML.

### Configurations
- pv.yaml: static ip and path to mount certs, configs, and data
- pv.yaml and pvc.yaml: storage size
- configmap.yaml: dns if public, static ip if private within LAN
- secrets.yaml: your jwt token and root admin password

### Deployment Steps
kubectl apply -f namespace.yaml
kubectl apply -f pv.yaml
kubectl apply -f pvc.yaml
kubectl apply -f configmap.yaml
kubectl apply -f secrets/secret.yaml
kubectl apply -f deploy.yaml


## Keeping traffic Local
By configuring Pi‑hole to override DNS resolution for your domain and pointing it to a local nginx reverse proxy, you can access your service via the same domain  without the traffic leaving your LAN.

### How It Works
- Public DNS still resolves your domain to a public IP (or Cloudflare) for the outside world.
- Pi‑hole acts as your local DNS server and overrides that resolution for clients on your network, returning your local server IP (e.g., 192.168.1.168).
- nginx listens on that local IP (or on the Kubernetes node) and proxies requests to your actual service (e.g., OpenCloud).
- The browser connects directly to your local nginx, sees a valid certificate (if configured), and all data stays local.

### Prerequisites
- A working Pi‑hole installation on your network (usually on a Raspberry Pi or as a Docker container).
- Your local server has a static IP address (e.g., 192.168.1.168).

### Deployment Steps
./copy-certs.sh (to copy the certs we created in previous steps to ./secrets/certs.yaml) 
kubectl apply -f ./secrets/certs.yaml
kubectl apply -f ./local/nginx-config.yaml
kubectl apply -f ./local/nginx-deployment.yaml
kubectl apply -f ./local/nginx-service-nodeport.yaml

### Set static ip and Configure Pi‑hole Local DNS
- Pihole UI can change, so go into details. Look for Local DNS Settings and add mapping for your domain to static ip of device hosting nginx

### Testing
Can test by temporarily changing the dns record on cloudflare. Original dns should still work, but only for devices on same lan.
