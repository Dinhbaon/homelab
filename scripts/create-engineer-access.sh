#!/bin/bash
# Usage: ./create-engineer-access.sh <engineer-name>
# Example: ./create-engineer-access.sh jane-doe

set -e

if [[ -z "$1" ]]; then
    echo "Usage: $0 <engineer-name>"
    echo "Example: $0 jane-doe"
    exit 1
fi

ENGINEER="$1"
NAMESPACE="aucra"
KUBECONFIG="${KUBECONFIG:-$HOME/kubeconfig}"

if [[ ! -f "$KUBECONFIG" ]]; then
    echo "Error: kubeconfig not found at $KUBECONFIG"
    echo "Set KUBECONFIG env var or ensure ~/kubeconfig exists"
    exit 1
fi

export KUBECONFIG

# Check cluster connectivity
if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    echo "Error: Cannot reach cluster or namespace '$NAMESPACE' does not exist"
    exit 1
fi

SA_NAME="engineer-$ENGINEER"
SECRET_NAME="$SA_NAME-token"

echo "Creating ServiceAccount: $SA_NAME"
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating RoleBinding..."
kubectl create rolebinding "$SA_NAME-rb" -n "$NAMESPACE" \
    --serviceaccount="$NAMESPACE:$SA_NAME" \
    --role=engineer-role \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Creating token secret..."
# Delete existing secret if present (e.g., from a previous run)
kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: $SA_NAME
type: kubernetes.io/service-account-token
EOF

# Wait for token to be populated
echo "Waiting for token to be created..."
for i in {1..10}; do
    TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
    if [[ -n "$TOKEN" ]]; then
        break
    fi
    sleep 1
done

if [[ -z "$TOKEN" ]]; then
    echo "Error: Token was not created. Check cluster logs."
    exit 1
fi

CA_CRT=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}' | base64 -d)
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

echo ""
echo "=========================================="
echo "Access created for: $ENGINEER"
echo "=========================================="
echo ""
echo "Share these credentials securely with the engineer."
echo ""
echo "Server: $SERVER"
echo "Namespace: $NAMESPACE"
echo ""
echo "Token:"
echo "$TOKEN"
echo ""
echo "CA Cert (ca.crt):"
echo "$CA_CRT"
echo ""
echo "=========================================="
echo "To configure kubectl, run:"
echo ""
echo "mkdir -p ~/.kube"
echo "cat > ~/.kube/config << 'KUBEEOF'"
echo "apiVersion: v1"
echo "kind: Config"
echo "clusters:"
echo "- cluster:"
echo "    certificate-authority-data: $(echo "$CA_CRT" | base64 -w0)"
echo "    server: $SERVER"
echo "  name: homelab"
echo "contexts:"
echo "- context:"
echo "    cluster: homelab"
echo "    namespace: $NAMESPACE"
echo "    user: $ENGINEER"
echo "  name: $ENGINEER@homelab"
echo "current-context: $ENGINEER@homelab"
echo "users:"
echo "- name: $ENGINEER"
echo "  user:"
echo "    token: $TOKEN"
echo "KUBEEOF"
echo ""
echo "=========================================="
