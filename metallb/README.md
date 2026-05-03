# MetalLB Quick Start

## What is MetalLB?

MetalLB is a load‑balancer implementation for bare‑metal Kubernetes clusters. It allows you to create `LoadBalancer` Services without relying on a cloud provider’s native load balancer.

MetalLB assigns external IP addresses from a configured pool and announces those IPs to your local network using standard routing protocols (L2 or BGP).

## Installation

Install MetalLB using the official manifest from GitHub:

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
```

Wait until all MetalLB pods are running:
```bash
kubectl get pods -n metallb-system --watch
```

Apply metallb-pool.yaml
```bash
kubectl apply -f metallb-pool.yaml
```

Verify It’s Working
```bash
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system
```

