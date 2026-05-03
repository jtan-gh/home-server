# Pihole Kubernetes
This project deploys [Pi‑hole](https://pi-hole.net/) (a network-wide ad blocker) on a bare-metal Kubernetes cluster using MetalLB for external network access. Personally I recommend this blocklist https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.plus.txt

## Prerequisites
- A Kubernetes cluster (v1.19+ recommended)
- `kubectl` configured to communicate with your cluster
- If using k3s, disable default lb
  - sudo nano /etc/systemd/system/k3s.service
  - add --disable servicelb to the end of ExecStart=/usr/local/bin/k3s server
- MetalLB already installed in the cluster (or included in your setup)
  - check /metallb
- Basic understanding of Kubernetes concepts

Project Structure
| File | Purpose |
|------|---------|
| `secrets.yaml` | Stores sensitive data like Pi‑hole admin password |
| `volume.yaml` | PersistentVolume and PersistentVolumeClaim for Pi‑hole data |
| `deployment.yaml` | Pi‑hole container deployment with volume mounts |
| `service.yaml` | Exposes Pi‑hole admin web interface (port 80) |

## Deployment order
kubectl apply -f ./secrets/secrets.yaml

kubectl apply -f volume.yaml   # includes pv and pvc

kubectl apply -f deployment.yaml

kubectl apply -f service.yaml   # admin UI

## Access admin page
kubectl get svc pihole
Then visit http://<CLUSTER-IP>:30080/admin/ on host or http://192.168.1.20:8080/admin
