# OpenCloud on Kubernetes – Deployment Guide
This guide covers deploying OpenCloud on a single-node Kubernetes cluster (k3s) using hostPath PersistentVolumes. All data is stored under /opencloud on the host. The setup includes automatic certificate generation, initialisation, and the main OpenCloud server.

## Prerequisites
- Kubernetes cluster (k3s recommended) with kubectl configured.
- A node with at least 4GB RAM and 20GB free disk space.
- Basic understanding of kubectl and YAML.

## Configurations
- pv.yaml: static ip and path to mount certs, configs, and data
- pv.yaml and pvc.yaml: storage size
- configmap.yaml: dns if public, static ip if private within LAN
- secrets.yaml: your jwt token and root admin password

## Deployment Steps
kubectl apply -f namespace.yaml
kubectl apply -f pv.yaml
kubectl apply -f pvc.yaml
kubectl apply -f configmap.yaml
kubectl apply -f secrets/secret.yaml
kubectl apply -f deploy.yaml
