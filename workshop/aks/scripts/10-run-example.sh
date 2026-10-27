#!/usr/bin/env bash
# Run ON THE JUMPBOX as azureuser: /opt/aks-ccc/10-run-example.sh
# Deploys examples/finos-ccc from the PR branch with the generated tfvars,
# then checks idempotency.
#
# The workshop settings (node pool, AKS tier, add-ons, registry SKU) come from
# landing-zone/workshop.auto.tfvars.json through the generated tfvars; the
# example reads them via workshop_variables.tf and workshop_override.tf, which
# this script copies into the clone. workshop_external_dns.tf adds the external-dns
# workload identity; 15-install-cluster-addons.sh (run at the end) installs
# Kyverno and external-dns.
#
# GRANT_ROUTE_TABLE=true (default) applies only when the landing zone has the
# egress firewall: it creates the identities first and grants the control-plane
# identity Network Contributor on the node subnet's route table, which the
# example does not do. Set it to false to test the PR exactly as written.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
GRANT_ROUTE_TABLE="${GRANT_ROUTE_TABLE:-true}"
[[ -n "${ROUTE_TABLE_ID:-}" ]] || GRANT_ROUTE_TABLE=false

[[ -f /opt/aks-ccc/READY ]] || { echo "Jumpbox bootstrap not finished; see /var/log/aks-ccc-bootstrap.log"; exit 1; }

az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"
echo "Deploying as: $(az account show --query user.name -o tsv)"

cd "$EXAMPLE_DIR"
echo "==> Updating to the latest $EXAMPLE_REPO_BRANCH"
git checkout -- . # discard edits made by earlier versions of this script
git pull --ff-only origin "$EXAMPLE_REPO_BRANCH"
git log --oneline -1
install -m 0600 /opt/aks-ccc/terraform.tfvars.json terraform.tfvars.json
rm -f lowcost_override.tf pr_fixes_override.tf # replaced by the workshop files
install -m 0644 /opt/aks-ccc/workshop_variables.tf /opt/aks-ccc/workshop_override.tf /opt/aks-ccc/workshop_external_dns.tf .
echo "==> Workshop settings"
jq 'with_entries(select(.key | startswith("workshop_")))' terraform.tfvars.json

terraform init -upgrade
terraform validate

# AKS fixes maxPods when a node pool is created; an existing cluster cannot take a new value.
want_max_pods="$(jq -r '.workshop_node_max_pods // 30' terraform.tfvars.json)"
if existing="$(terraform output -raw cluster_name 2>/dev/null)" && [[ -n "$existing" ]]; then
  have_max_pods="$(az aks nodepool show -g "$RESOURCE_GROUP" --cluster-name "$existing" -n systempool --query maxPods -o tsv 2>/dev/null || true)"
  if [[ -n "$have_max_pods" && "$have_max_pods" != "$want_max_pods" ]]; then
    echo "Cluster $existing has maxPods $have_max_pods per node; the settings ask for $want_max_pods."
    echo "AKS cannot change it on an existing node pool. Rebuild the cluster:"
    echo "  /opt/aks-ccc/95-destroy-ccc-tests.sh   # only if you set up the CCC tests"
    echo "  /opt/aks-ccc/90-destroy-example.sh"
    echo "  /opt/aks-ccc/10-run-example.sh"
    exit 1
  fi
fi

if [[ "$GRANT_ROUTE_TABLE" == "true" ]]; then
  echo "==> Stage 1: create the cluster identities only"
  terraform apply -target='module.cluster_identities'

  principal_id="$(az identity list --resource-group "$RESOURCE_GROUP" \
    --query "[?starts_with(name, 'id-ccc-control-plane-')] | [0].principalId" -o tsv)"
  [[ -n "$principal_id" ]] || { echo "control-plane identity not found"; exit 1; }

  echo "==> Granting Network Contributor on the route table to $principal_id"
  if [[ -z "$(az role assignment list --assignee "$principal_id" --scope "$ROUTE_TABLE_ID" --role "Network Contributor" --query '[0].id' -o tsv)" ]]; then
    az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
      --role "Network Contributor" --scope "$ROUTE_TABLE_ID" -o none
    echo "Waiting 60s for RBAC propagation"
    sleep 60
  fi
fi

echo "==> Full plan"
terraform plan -out=finos-ccc.tfplan
read -r -p "Review the plan above. Apply it? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; }
terraform apply finos-ccc.tfplan

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

# The API server is private: link its DNS zone to the hub VNet so the jumpbox can
# resolve it (outside Terraform; 90-destroy-example.sh removes the link).
ZONE_ID="$(terraform output -raw private_dns_zone_id)"
ZONE_NAME="${ZONE_ID##*/}"
ZONE_RG="$(cut -d/ -f5 <<<"$ZONE_ID")"
PRIVATE_FQDN="$(terraform output -raw private_fqdn)"
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

/opt/aks-ccc/15-install-cluster-addons.sh

# Pod Security Admission: enforce the baseline profile in every namespace except
# kube-system, where AKS runs privileged system pods (Cilium, kube-proxy, CSI
# drivers) that baseline would keep from starting on new nodes. kube-system is
# labeled privileged instead, so every namespace has an explicit decision
# (CCC.K8S.CN11.AR01). Namespaces that already enforce restricted (the CCC
# fixtures) are left alone. kubectl prints a warning for each running pod that
# baseline would reject.
echo "==> Pod Security: enforce=baseline (version latest) in every namespace, privileged in kube-system"
mapfile -t PSA_NAMESPACES < <(kubectl get namespaces -o json |
  jq -r '.items[] | select(.metadata.name != "kube-system")
    | select(.metadata.labels["pod-security.kubernetes.io/enforce"] != "restricted") | .metadata.name')
kubectl label --overwrite namespace "${PSA_NAMESPACES[@]}" \
  pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest
kubectl label --overwrite namespace kube-system pod-security.kubernetes.io/enforce=privileged
kubectl get namespaces -L pod-security.kubernetes.io/enforce,pod-security.kubernetes.io/enforce-version

echo "Next: /opt/aks-ccc/20-verify-cluster.sh"
