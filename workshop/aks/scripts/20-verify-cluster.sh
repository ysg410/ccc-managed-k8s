#!/usr/bin/env bash
# Run ON THE JUMPBOX after 10-run-example.sh. Links the AKS API private DNS zone
# to the hub VNet (so the jumpbox can resolve the private API server), fetches
# Entra credentials and checks the security settings the example claims.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
cd "$EXAMPLE_DIR"

CLUSTER_NAME="$(terraform output -raw cluster_name)"
PRIVATE_FQDN="$(terraform output -raw private_fqdn)"
ZONE_ID="$(terraform output -raw private_dns_zone_id)"
ZONE_NAME="${ZONE_ID##*/}"
ZONE_RG="$(cut -d/ -f5 <<<"$ZONE_ID")"

echo "==> Linking $ZONE_NAME to the hub VNet"
if ! az network private-dns link vnet show -g "$ZONE_RG" -z "$ZONE_NAME" -n hub-vnet -o none 2>/dev/null; then
  az network private-dns link vnet create -g "$ZONE_RG" -z "$ZONE_NAME" -n hub-vnet \
    --virtual-network "$HUB_VNET_ID" --registration-enabled false -o none
fi
for _ in $(seq 1 30); do
  ip="$(dig +short "$PRIVATE_FQDN" | tail -1)"
  [[ -n "$ip" ]] && break
  sleep 10
done
echo "$PRIVATE_FQDN -> ${ip:-unresolved}"

echo "==> Cluster settings"
az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query '{
  provisioningState: provisioningState,
  kubernetesVersion: currentKubernetesVersion,
  privateCluster: apiServerAccessProfile.enablePrivateCluster,
  publicFqdn: apiServerAccessProfile.enablePrivateClusterPublicFqdn,
  vnetIntegration: apiServerAccessProfile.enableVnetIntegration,
  outboundType: networkProfile.outboundType,
  networkPlugin: networkProfile.networkPluginMode,
  dataplane: networkProfile.networkDataplane,
  networkPolicy: networkProfile.networkPolicy,
  podCidr: networkProfile.podCidr,
  kmsEnabled: securityProfile.azureKeyVaultKms.enabled,
  kmsNetworkAccess: securityProfile.azureKeyVaultKms.keyVaultNetworkAccess,
  diskEncryptionSet: diskEncryptionSetId,
  entraManaged: aadProfile.managed,
  oidcIssuer: oidcIssuerProfile.enabled,
  workloadIdentity: securityProfile.workloadIdentity.enabled,
  localAccountsDisabled: disableLocalAccounts
}' -o yaml

echo "==> kubectl via Entra (you must be in the admin group)"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes -o wide
kubectl get pods -n kube-system

echo "==> KMS smoke test: create and read a secret"
kubectl create secret generic kms-smoke-test --from-literal=hello=world --dry-run=client -o yaml | kubectl apply -f -
kubectl get secret kms-smoke-test -o jsonpath='{.data.hello}' | base64 -d; echo
kubectl delete secret kms-smoke-test

echo "==> Nodes have no public IPs"
az vmss list -g "$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query nodeResourceGroup -o tsv)" \
  --query "[].{name:name, publicIp:virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].publicIpAddressConfiguration}" -o table
