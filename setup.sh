#!/bin/bash
set -e

# ===== CONFIGURE THESE =====
TUNNEL_UUID="06e1e9ae-33f4-45ae-a9b6-9826f897f2a9"   # your actual tunnel UUID
NAMESPACE="cloudflared"
# ===========================

CRED_FILE="$HOME/.cloudflared/${TUNNEL_UUID}.json"

if [ ! -f "$CRED_FILE" ]; then
    echo "ERROR: Credentials file not found at $CRED_FILE"
    exit 1
fi

# Create namespace (ignore if exists)
kubectl create ns "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create/update secret from the credentials file
kubectl create secret generic cloudflared-auth \
    --namespace "$NAMESPACE" \
    --from-file=tunnel.json="$CRED_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Apply ConfigMap (assuming tunnel UUID is already inside it)
kubectl apply -f ./cloudflare/configmap.yaml

# Apply Deployment
kubectl apply -f ./cloudflare/deployment.yaml

# Optional debug pod
if [ -f debug-pod.yaml ]; then
    kubectl apply -f ./cloudflare/debug-pod.yaml
fi

echo "[+] Done. Check logs: kubectl logs -n $NAMESPACE deployment/cloudflared-tunnel"
