#!/usr/bin/env bash
# Run on your laptop or in Azure Cloud Shell (bash) BEFORE the landing zone.
# Checks the subscription, registers providers, checks VM SKUs/zones and quota,
# requests quota if needed, creates an SSH key and writes landing-zone/terraform.tfvars.
#
#   LOCATION=centralindia ./scripts/00-preflight.sh
#
# LOCATION picks the region (default: the one in terraform.tfvars, else
# centralindia) and updates terraform.tfvars if it differs. Every later step
# takes the region from there. SUBSCRIPTION_ID (default: the current az account)
# is written to a new terraform.tfvars; TENANT_ID, if set, signs in to that tenant.
#
# Checks the node pool and jumpbox sizes in landing-zone/workshop.auto.tfvars.json
# (2 x Standard_D4s_v5 in zone 1 + Standard_B2als_v2 = 10 vCPUs by default, so a
# Free Trial subscription with its 4 vCPU cap must be upgraded first). Edit that
# file to change the sizing, then rerun.
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$ROOT/landing-zone/terraform.tfvars"
SETTINGS="$ROOT/landing-zone/workshop.auto.tfvars.json"
STATE="$ROOT/landing-zone/terraform.tfstate"

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Region and subscription: the environment variable, else the value already in
# terraform.tfvars, else the default. Either can change only while no landing
# zone is deployed from this directory (its local state belongs to one of each).
tfvar() { [[ -f "$TFVARS" ]] && sed -n "s/^$1 *= *\"\(.*\)\".*/\1/p" "$TFVARS" || true; }
set_tfvar() {
  sed -i.bak "/^$1 *=/d" "$TFVARS" && rm -f "$TFVARS.bak"
  printf '%-21s = "%s"\n' "$1" "$2" >> "$TFVARS"
  echo "Set $1 = \"$2\""
}
DEPLOYED=false
[[ -f "$STATE" ]] && jq -e '(.resources // []) | length > 0' "$STATE" >/dev/null && DEPLOYED=true
TFVARS_LOCATION="$(tfvar location)"
TFVARS_SUBSCRIPTION="$(tfvar subscription_id)"

LOCATION="${LOCATION:-${TFVARS_LOCATION:-centralindia}}"
[[ "$LOCATION" =~ ^[a-z0-9]+$ ]] || fail "LOCATION must be a short region name such as centralindia (az account list-locations -o table)"
if [[ -n "$TFVARS_LOCATION" && "$TFVARS_LOCATION" != "$LOCATION" ]] && $DEPLOYED; then
  fail "The landing zone is deployed in $TFVARS_LOCATION. Destroy it (and the cluster) before moving to $LOCATION."
fi
echo "Region: $LOCATION"

for cmd in az terraform jq curl ssh-keygen; do
  command -v "$cmd" >/dev/null || fail "$cmd is not installed"
done

NODE_SIZE="$(jq -r '.aks_node_vm_size' "$SETTINGS")"
NODE_MAX="$(jq -r '.aks_node_max_count' "$SETTINGS")"
NODE_ZONES="$(jq -r '.aks_node_zones | join(" ")' "$SETTINGS")"
JUMPBOX_SIZE="$(jq -r '.jumpbox_vm_size' "$SETTINGS")"

step "Azure login"
if [[ -n "${TENANT_ID:-}" ]]; then
  [[ "$(az account show --query tenantId -o tsv 2>/dev/null || true)" == "$TENANT_ID" ]] ||
    az login --use-device-code --tenant "$TENANT_ID" >/dev/null
else
  az account show >/dev/null 2>&1 || az login --use-device-code >/dev/null
fi
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-${TFVARS_SUBSCRIPTION:-$(az account show --query id -o tsv)}}"
if [[ -n "$TFVARS_SUBSCRIPTION" && "$TFVARS_SUBSCRIPTION" != "$SUBSCRIPTION_ID" ]] && $DEPLOYED; then
  fail "The landing zone is deployed in subscription $TFVARS_SUBSCRIPTION. Destroy it (and the cluster) first, or use a separate copy of workshop/ for $SUBSCRIPTION_ID."
fi
az account set --subscription "$SUBSCRIPTION_ID"
[[ -z "${TENANT_ID:-}" || "$(az account show --query tenantId -o tsv)" == "$TENANT_ID" ]] ||
  fail "Subscription $SUBSCRIPTION_ID is not in tenant $TENANT_ID"
az account show --query "{subscription:name, id:id, tenant:tenantId, user:user.name}" -o table
# Recent Azure CLI versions no longer return subscriptionPolicies from `az account show`.
QUOTA_ID="$(az rest --method get --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID?api-version=2022-12-01" \
  --query 'subscriptionPolicies.quotaId' -o tsv 2>/dev/null || true)"
echo "Subscription offer (quotaId): ${QUOTA_ID:-unknown}"
FREE_TRIAL=false
if [[ "$QUOTA_ID" == FreeTrial* ]]; then
  FREE_TRIAL=true
  echo "NOTE: Free Trial caps regional vCPUs at 4 and the cap cannot be raised. Upgrade to Pay-As-You-Go:"
  echo "      portal > Subscriptions > this subscription > Upgrade subscription (remaining credit is kept)."
fi

step "Registering Microsoft.Compute/EncryptionAtHost (the example enables encryption at host)"
az feature register --namespace Microsoft.Compute --name EncryptionAtHost -o none
for _ in $(seq 1 60); do
  state="$(az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv)"
  [[ "$state" == "Registered" ]] && break
  sleep 10
done
echo "EncryptionAtHost: $state"
[[ "$state" == "Registered" ]] || fail "EncryptionAtHost did not register"

step "Registering resource providers"
# Compute is re-registered below so the EncryptionAtHost feature takes effect.
PROVIDERS=(Microsoft.ContainerService Microsoft.Network Microsoft.Compute Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Quota
  Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.PolicyInsights Microsoft.Security)
for p in "${PROVIDERS[@]}"; do az provider register --namespace "$p" >/dev/null; done
for p in "${PROVIDERS[@]}"; do
  for _ in $(seq 1 60); do
    state="$(az provider show --namespace "$p" --query registrationState -o tsv)"
    [[ "$state" == "Registered" ]] && break
    sleep 10
  done
  echo "$p: $state"
  [[ "$state" == "Registered" ]] || fail "$p did not register"
done

# Prints {family, vcpus, regional_restricted, usable_zones} for a VM size, or null.
# Zones restricted for this subscription (NotAvailableForSubscription) are not usable.
sku_info() {
  az vm list-skus --location "$LOCATION" --size "$1" --resource-type virtualMachines --all \
    --query "[?name=='$1'] | [0]" -o json |
    jq -c 'if . == null then null else {
      family,
      vcpus: (.capabilities[] | select(.name == "vCPUs") | .value | tonumber),
      regional_restricted: any(.restrictions[]?; .type == "Location"),
      usable_zones: (((.locationInfo[0].zones // []) - [.restrictions[]? | select(.type == "Zone") | .restrictionInfo.zones[]?]) | sort)
    } end'
}

step "Checking $NODE_SIZE (zones: $NODE_ZONES) and $JUMPBOX_SIZE in $LOCATION"
node_sku="$(sku_info "$NODE_SIZE")"
jump_sku="$(sku_info "$JUMPBOX_SIZE")"
for pair in "$NODE_SIZE|$node_sku" "$JUMPBOX_SIZE|$jump_sku"; do
  size="${pair%%|*}" sku="${pair#*|}"
  [[ "$sku" != "null" ]] || fail "$size is not offered in $LOCATION"
  echo "$size: $sku"
  [[ "$(jq '.regional_restricted' <<<"$sku")" == "false" ]] || fail "$size is restricted for this subscription in $LOCATION; pick another size"
done
for z in $NODE_ZONES; do
  jq -e --arg z "$z" '.usable_zones | index($z)' <<<"$node_sku" >/dev/null ||
    fail "$NODE_SIZE is not usable in zone $z for this subscription. Usable zones: $(jq -r '.usable_zones | join(" ")' <<<"$node_sku"). Change aks_node_zones or aks_node_vm_size in $SETTINGS."
done

NODE_FAMILY="$(jq -r '.family' <<<"$node_sku")"
JUMP_FAMILY="$(jq -r '.family' <<<"$jump_sku")"
NODE_VCPUS=$((NODE_MAX * $(jq '.vcpus' <<<"$node_sku"))) # autoscaler maximum
JUMP_VCPUS="$(jq '.vcpus' <<<"$jump_sku")"
# A jumpbox that is already deployed is in current usage; don't count it twice.
DEPLOYED_JUMP_VCPUS=0
if [[ -f "$ROOT/landing-zone/terraform.tfstate" ]] &&
   jq -e 'any(.resources[]?; .type == "azurerm_linux_virtual_machine")' "$ROOT/landing-zone/terraform.tfstate" >/dev/null; then
  echo "Jumpbox already deployed; its $JUMP_VCPUS vCPUs are not counted twice"
  DEPLOYED_JUMP_VCPUS=$JUMP_VCPUS
fi
REQUIRED_VCPUS=$((NODE_VCPUS + JUMP_VCPUS))
# Lines: <usage name> <vCPUs needed> <vCPUs of the deployed jumpbox in its usage>
if [[ "$NODE_FAMILY" == "$JUMP_FAMILY" ]]; then
  QUOTA_CHECKS="cores $REQUIRED_VCPUS $DEPLOYED_JUMP_VCPUS
$NODE_FAMILY $REQUIRED_VCPUS $DEPLOYED_JUMP_VCPUS"
else
  QUOTA_CHECKS="cores $REQUIRED_VCPUS $DEPLOYED_JUMP_VCPUS
$NODE_FAMILY $NODE_VCPUS 0
$JUMP_FAMILY $JUMP_VCPUS $DEPLOYED_JUMP_VCPUS"
fi

step "Checking vCPU quota in $LOCATION (need $REQUIRED_VCPUS; AKS upgrade surge is not included)"
SCOPE="/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Compute/locations/$LOCATION"
az extension add --name quota --only-show-errors >/dev/null 2>&1 || true
USAGE="$(az vm list-usage --location "$LOCATION" -o json)"
QUOTA_OK=true
while read -r q need deployed <&3; do
  read -r used limit < <(jq -r --arg q "$q" '.[] | select(.name.value == $q) | "\(.currentValue) \(.limit)"' <<<"$USAGE")
  [[ -n "${limit:-}" ]] || fail "No usage entry named $q in $LOCATION"
  used=$((used - deployed))
  echo "$q: used by other VMs=$used limit=$limit need=$need"
  if (( used + need > limit )); then
    # Attempted even when the offer still reads Free Trial: right after an
    # upgrade, quotaId can lag behind the new limits.
    echo "  requesting $q = $((used + need)) ..."
    if az quota update --resource-name "$q" --scope "$SCOPE" --resource-type dedicated \
         --limit-object value="$((used + need))" --only-show-errors -o none; then
      echo "  quota request accepted"
    else
      QUOTA_OK=false
      echo "  automatic request failed. Request it in the portal: Subscriptions > Usage + quotas > Compute > $LOCATION"
      if $FREE_TRIAL; then echo "  (Free Trial quota cannot be raised; upgrade to Pay-As-You-Go first)"; fi
    fi
  fi
done 3<<<"$QUOTA_CHECKS"
$QUOTA_OK || fail "Quota is too low. Raise it or change the sizes, then rerun this script."

step "Kubernetes versions in $LOCATION (GA)"
az aks get-versions --location "$LOCATION" --query "values[?isPreview!=\`true\`].version" -o tsv | tr '\n' ' '
echo

step "SSH key"
[[ -f "$SSH_KEY" ]] || ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_KEY"
echo "Using $SSH_KEY.pub"

step "Writing $TFVARS"
MY_IP="$(curl -fsS https://api.ipify.org)"
if [[ -f "$TFVARS" ]]; then
  [[ "$TFVARS_SUBSCRIPTION" == "$SUBSCRIPTION_ID" ]] || set_tfvar subscription_id "$SUBSCRIPTION_ID"
  [[ "$TFVARS_LOCATION" == "$LOCATION" ]] || set_tfvar location "$LOCATION"
  echo "Otherwise kept as is. Your current public IP is $MY_IP/32."
else
  cat > "$TFVARS" <<EOF
subscription_id       = "$SUBSCRIPTION_ID"
location              = "$LOCATION"
admin_ssh_source_cidr = "$MY_IP/32"
ssh_public_key_path   = "$SSH_KEY.pub"
# kubernetes_version  = "1.33"   # default: latest GA in the region
EOF
  cat "$TFVARS"
fi

echo
echo "Preflight OK. Next: cd landing-zone && terraform init && terraform apply"
