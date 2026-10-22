#!/usr/bin/env bash
# Run ON THE JUMPBOX after 20-verify-cluster.sh: /opt/aks-ccc/30-deploy-traderx.sh
# Applies /opt/aks-ccc/traderx.yaml (examples/traderx/traderx-aks-demo.yaml from
# this repository, delivered by the landing zone) and waits for every TraderX
# deployment.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
MANIFEST="${MANIFEST:-/opt/aks-ccc/traderx.yaml}"
NAMESPACE=traderx

[[ -f "$MANIFEST" ]] || { echo "$MANIFEST not found. From your laptop run workshop/aks/scripts/05-sync-jumpbox.sh, then rerun $0"; exit 1; }

az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"
CLUSTER_NAME="$(terraform -chdir="$EXAMPLE_DIR" output -raw cluster_name)"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

echo "==> Applying $MANIFEST"
kubectl apply -f "$MANIFEST"

echo "==> Waiting for deployments in $NAMESPACE"
if ! kubectl -n "$NAMESPACE" wait deployment --all --for=condition=Available --timeout=15m; then
  kubectl -n "$NAMESPACE" get pods -o wide
  echo "Some deployments are not ready. Check: kubectl -n $NAMESPACE describe pod <name> / kubectl -n $NAMESPACE logs <name>"
  exit 1
fi
kubectl -n "$NAMESPACE" get pods,svc

cat <<EOF

TraderX is running. All services are ClusterIP; to open it from your laptop:
  on the jumpbox:  kubectl -n $NAMESPACE port-forward svc/edge-proxy 8080:8080
  on your laptop:  ssh -L 8080:localhost:8080 azureuser@<jumpbox-ip>   then open http://localhost:8080
Grafana: same with svc/grafana 3000:3000.
EOF
