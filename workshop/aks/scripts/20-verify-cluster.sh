#!/usr/bin/env bash
# Run ON THE JUMPBOX after 10-run-example.sh (which links the AKS API private DNS
# zone to the hub VNet). Checks the jumpbox resolves the private API server,
# fetches Entra credentials and checks the security settings the example claims.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
cd "$EXAMPLE_DIR"

CLUSTER_NAME="$(terraform output -raw cluster_name)"
PRIVATE_FQDN="$(terraform output -raw private_fqdn)"
ip="$(dig +short "$PRIVATE_FQDN" | tail -1)"
echo "$PRIVATE_FQDN -> ${ip:-unresolved}"
[[ -n "$ip" ]] || { echo "The jumpbox cannot resolve the API server; rerun /opt/aks-ccc/10-run-example.sh"; exit 1; }

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
