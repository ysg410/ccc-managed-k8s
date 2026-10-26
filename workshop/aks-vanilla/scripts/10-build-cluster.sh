#!/usr/bin/env bash
# Run ON THE JUMPBOX after 05-sync-jumpbox.sh: /opt/aks-ccc/vanilla/10-build-cluster.sh
# Builds the plain AVM cluster (the module's published default example, v0.8.5) from
# ~/aks-vanilla, checks idempotency, fetches Entra credentials and prints the
# cluster's security-relevant settings for comparison with the hardened cluster.
# Run the hardened cluster or this one, not both: two clusters exceed the 16-vCPU quota.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
LZ_RESOURCE_GROUP="$RESOURCE_GROUP" # the hardened cluster's; target.sh replaces RESOURCE_GROUP
# shellcheck source=/dev/null
source /opt/aks-ccc/vanilla/target.sh

az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"
echo "Deploying as: $(az account show --query user.name -o tsv)"

cd "$EXAMPLE_DIR"
[[ -f terraform.tfvars.json ]] || { echo "$EXAMPLE_DIR/terraform.tfvars.json missing: run workshop/aks-vanilla/scripts/05-sync-jumpbox.sh on your laptop."; exit 1; }

if [[ -n "$(az aks list -g "$LZ_RESOURCE_GROUP" --query '[0].name' -o tsv 2>/dev/null || true)" ]]; then
  echo "WARNING: the hardened workshop cluster in $LZ_RESOURCE_GROUP still exists; with this one they exceed"
  echo "         the 16-vCPU DSv5 quota. Destroy it first: /opt/aks-ccc/95-destroy-ccc-tests.sh, /opt/aks-ccc/90-destroy-example.sh"
fi

terraform init -upgrade
terraform validate
terraform plan -out=vanilla.tfplan
read -r -p "Review the plan above. Apply it? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; }
terraform apply vanilla.tfplan

echo "==> Idempotency check (exit 0 = no changes, 2 = drift)"
set +e
terraform plan -detailed-exitcode -input=false
rc=$?
set -e
case $rc in
  0) echo "IDEMPOTENT: no changes after apply" ;;
  2) echo "DRIFT: the second plan wants changes (see above)" ;;
  *) echo "Plan failed with exit code $rc" ;;
esac
terraform output

CLUSTER_NAME="$(terraform output -raw cluster_name)"
RESOURCE_GROUP="$(terraform output -raw resource_group_name)"
echo "==> Cluster access (Entra, via the landing zone's admin group)"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes -o wide

echo "==> Cluster settings"
az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query '{
  kubernetesVersion: currentKubernetesVersion,
  privateCluster: apiServerAccessProfile.enablePrivateCluster,
  fqdn: fqdn,
  localAccountsDisabled: disableLocalAccounts,
  entraManaged: aadProfile.managed,
  azureRbac: aadProfile.enableAzureRbac,
  networkPlugin: networkProfile.networkPlugin,
  networkPluginMode: networkProfile.networkPluginMode,
  networkPolicy: networkProfile.networkPolicy,
  outboundType: networkProfile.outboundType,
  oidcIssuer: oidcIssuerProfile.enabled,
  workloadIdentity: securityProfile.workloadIdentity.enabled,
  kms: securityProfile.azureKeyVaultKms.enabled,
  defender: securityProfile.defender.securityMonitoring.enabled,
  azurePolicy: addonProfiles.azurepolicy.enabled,
  upgradeChannel: autoUpgradeProfile.upgradeChannel
}' -o yaml

echo "Next: /opt/aks-ccc/vanilla/40-setup-ccc-tests.sh"
