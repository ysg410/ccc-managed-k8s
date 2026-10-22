#!/usr/bin/env bash
# Run ON THE JUMPBOX as azureuser: /opt/aks-ccc/10-run-example.sh
# Deploys examples/finos-ccc from the PR branch with the generated tfvars,
# then checks idempotency.
#
# The workshop settings (node pool, AKS tier, add-ons, registry SKU) come from
# landing-zone/workshop.auto.tfvars.json through the generated tfvars; the
# example reads them via workshop_variables.tf and workshop_override.tf, which
# this script copies into the clone.
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
install -m 0644 /opt/aks-ccc/workshop_variables.tf /opt/aks-ccc/workshop_override.tf .
echo "==> Workshop settings"
jq 'with_entries(select(.key | startswith("workshop_")))' terraform.tfvars.json

terraform init -upgrade
terraform validate

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
echo "Next: /opt/aks-ccc/20-verify-cluster.sh"
