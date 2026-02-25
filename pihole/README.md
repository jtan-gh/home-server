# Pihole Kubernetes
This project deploys [Pi‑hole](https://pi-hole.net/) (a network-wide ad blocker) on a bare-metal Kubernetes cluster using MetalLB for external network access.

## Prerequisites
- A Kubernetes cluster (v1.19+ recommended)
- `kubectl` configured to communicate with your cluster
- MetalLB already installed in the cluster (or included in your setup)
- Basic understanding of Kubernetes concepts

Project Structure
| File | Purpose |
|------|---------|
| `metallb.yaml` | Configures MetalLB IP address pool and L2 advertisement |
| `secrets.yaml` | Stores sensitive data like Pi‑hole admin password |
| `volume.yaml` | PersistentVolume and PersistentVolumeClaim for Pi‑hole data |
| `deployment.yaml` | Pi‑hole container deployment with volume mounts |
| `service.yaml` | Exposes Pi‑hole admin web interface (port 80) |
| `loadbalancer.yaml` | LoadBalancer service for DNS (port 53 TCP/UDP) |

## Deployment order
kubectl apply -f metallb.yaml
kubectl apply -f secrets.yaml
kubectl apply -f volume.yaml   # includes pv and pvc
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml   # admin UI
kubectl apply -f loadbalancer.yaml   # DNS service

## Access admin page
kubectl get svc pihole
Then visit http://<CLUSTER-IP>:30080/admin/