#!/bin/bash

set -e

TUNNEL_ID="06e1e9ae-33f4-45ae-a9b6-9826f897f2a9"
HOSTNAME="jtanprojects.com"

TUNNEL_JSON_PATH="$HOME/.cloudflared/${TUNNEL_ID}.json"
CONFIG_MAP_FILE="/cloudflare/configmap.yaml"
SECRET_FILE="/cloudflare/secrets/secrets.yaml"
DEPLOYMENT_FILE="/cloudflare/deployment.yaml"
DEBUG_POD_FILE="debug-pod.yaml"

echo "Creating namespace 'cloudflared' if not exists..."
kubectl get ns cloudflared >/dev/null 2>&1 || kubectl create ns cloudflared

echo "Encoding tunnel.json..."
ENCODED_TUNNEL_JSON=$(base64 -w 0 "$TUNNEL_JSON_PATH")

echo "Generating cloudflared-auth secret manifest..."

cat > "$SECRET_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-auth
  namespace: cloudflared
type: Opaque
data:
  tunnel.json: $ENCODED_TUNNEL_JSON
EOF

echo "Applying Secret..."
kubectl apply -f "$SECRET_FILE"

echo "Replacing tunnelID inside cloudflared ConfigMap..."
sed -i "s/^[[:space:]]*tunnel: .*/    tunnel: $TUNNEL_ID/" "$CONFIG_MAP_FILE"

echo "Applying ConfigMap..."
kubectl apply -f "$CONFIG_MAP_FILE"

echo "Applying Deployment..."
kubectl apply -f "$DEPLOYMENT_FILE"

echo "Creating debug pod! You can optionally run:"
kubectl apply -f $DEBUG_POD_FILE
echo "To connect to debug pod with sh use..."
echo "kubectl exec -n cloudflared -it debug-config-check -- sh"
