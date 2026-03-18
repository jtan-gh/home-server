#!/bin/bash

#!/bin/bash
# Script: generate-secret.sh
# Usage: ./generate-secret.sh
# Generates ./secrets/certs.yaml from /opencloud/certs/server.{key,pem}

set -e  # exit on error

# Source certificate paths
CERT_DIR="/opencloud/certs"
KEY_FILE="$CERT_DIR/server.key"
CERT_FILE="$CERT_DIR/server.pem"

# Destination directory (relative to script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/secrets"
OUTPUT_FILE="$SECRETS_DIR/certs.yaml"

# Check that source files exist
if [ ! -f "$KEY_FILE" ]; then
    echo "Error: Private key not found at $KEY_FILE" >&2
    exit 1
fi
if [ ! -f "$CERT_FILE" ]; then
    echo "Error: Certificate not found at $CERT_FILE" >&2
    exit 1
fi

# Create secrets directory if needed
mkdir -p "$SECRETS_DIR"

# Base64 encode (no line wrapping)
KEY_B64=$(base64 -w0 < "$KEY_FILE")
CERT_B64=$(base64 -w0 < "$CERT_FILE")

# Write the YAML file
cat > "$OUTPUT_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: opencloud-tls
  namespace: opencloud
type: kubernetes.io/tls
data:
  tls.key: $KEY_B64
  tls.crt: $CERT_B64
EOF

echo "Secret YAML written to $OUTPUT_FILE"
