#!/usr/bin/env bash
# Run ON THE JUMPBOX to remove everything 40-setup-ccc-tests.sh created:
#   /opt/aks-ccc/95-destroy-ccc-tests.sh
# Run it before 90-destroy-example.sh: the identity, storage account and Entra
# app are not in any Terraform state, and the Entra app outlives the resource group.
# Keeps the toolchain, the CCC repo clone and ~/ccc-tests/results.
set -uo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
WORK_DIR="$HOME/ccc-tests"
ENV_FILE="$WORK_DIR/ccc-test-env.sh"
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found; nothing to remove."; exit 0; }
# shellcheck source=/dev/null
source "$ENV_FILE"

az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"

echo "==> In-cluster fixtures"
if kubectl get --raw /readyz >/dev/null 2>&1; then
  kubectl delete validatingwebhookconfiguration ccc-admission-webhook-probe --ignore-not-found
  kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy --ignore-not-found \
    ccc-deny-tag-only-images ccc-deny-static-cloud-credentials ccc-deny-blocked-storage-class
  kubectl delete namespace --ignore-not-found \
    ccc-test ccc-network-control ccc-admission-webhook-probe ccc-admission-webhook-test
  kubectl delete storageclass --ignore-not-found ccc-approved-sc ccc-blocked-sc
else
  echo "Cluster not reachable; skipping (nothing to do if it was destroyed)."
fi

echo "==> Azure fixtures"
az ad app delete --id "$AZURE_TEST_USER_NO_ACCESS_CLIENT_ID" 2>/dev/null && echo "Deleted Entra app $AZURE_TEST_USER_NO_ACCESS_USER_NAME"
az storage account delete -g "$RESOURCE_GROUP" -n "$WI_STORAGE_ACCOUNT" --yes 2>/dev/null && echo "Deleted $WI_STORAGE_ACCOUNT"
az identity delete -g "$RESOURCE_GROUP" -n "$WI_NAME" 2>/dev/null && echo "Deleted $WI_NAME"
if ACR="$(terraform -chdir="$EXAMPLE_DIR" output -raw container_registry_login_server 2>/dev/null)"; then
  az acr repository delete -n "${ACR%%.*}" --repository ccc-admission-webhook-probe --yes 2>/dev/null && echo "Deleted the webhook probe image"
fi

echo "==> Local files"
sudo rm -f /usr/local/share/ca-certificates/ccc-reachability-tunnel.crt && sudo update-ca-certificates --fresh >/dev/null
rm -rf "$ENV_FILE" "$WORK_DIR/webhook-tls" "$WORK_DIR/tunnel.crt" "$WORK_DIR/tunnel.key" "$WORK_DIR/reachability-secret"
echo "Done. Results are kept in $WORK_DIR/results."
