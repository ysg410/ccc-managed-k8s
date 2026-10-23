#!/usr/bin/env bash
# Run ON THE JUMPBOX to remove the AKS cluster and everything the example created.
# Afterwards destroy the landing zone from your laptop: cd landing-zone && terraform destroy
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
cd "$EXAMPLE_DIR"

# The hub link was added by 10-run-example.sh outside Terraform. A private DNS
# zone with remaining VNet links cannot be deleted, so remove it first.
if ZONE_ID="$(terraform output -raw private_dns_zone_id 2>/dev/null)" && [[ -n "$ZONE_ID" ]]; then
  az network private-dns link vnet delete -g "$(cut -d/ -f5 <<<"$ZONE_ID")" -z "${ZONE_ID##*/}" -n hub-vnet --yes 2>/dev/null || true
fi

terraform destroy

echo "Note: the Key Vault and keys are soft-deleted (purge protection, 90 days). They cost nothing"
echo "and do not block deleting the resource group."
