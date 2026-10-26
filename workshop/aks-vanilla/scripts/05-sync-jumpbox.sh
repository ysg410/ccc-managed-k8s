#!/usr/bin/env bash
# Run on your laptop, from anywhere: workshop/aks-vanilla/scripts/05-sync-jumpbox.sh
# Copies the vanilla cluster's Terraform to ~/aks-vanilla on the workshop jumpbox
# (keeping its state) and the vanilla scripts to /opt/aks-ccc/vanilla, and writes
# terraform.tfvars.json from the landing zone (subscription, region, admin group).
# Needs the landing zone from workshop/aks and its jumpbox.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LZ="$ROOT/../aks/landing-zone"
ENV_SH="$LZ/generated/jumpbox/env.sh"

[[ -f "$ENV_SH" ]] || { echo "$ENV_SH not found: apply workshop/aks/landing-zone first."; exit 1; }
TARGET="$(terraform -chdir="$LZ" output -raw jumpbox_ssh | awk '{print $2}')"
ADMIN_GROUP="$(terraform -chdir="$LZ" output -raw aks_admin_group_object_id)"
# shellcheck source=/dev/null
read -r SUBSCRIPTION_ID LOCATION < <(source "$ENV_SH" && echo "$SUBSCRIPTION_ID $LOCATION")

TFVARS="$(jq -n --arg s "$SUBSCRIPTION_ID" --arg l "$LOCATION" --arg g "$ADMIN_GROUP" '{
  subscription_id: $s,
  location: $l,
  cluster_admin_group_object_ids: [$g],
  enable_telemetry: false
}')"
echo "==> Inputs"
echo "$TFVARS"

ssh "$TARGET" 'test -f /opt/aks-ccc/READY' || {
  echo "The jumpbox is still bootstrapping (az, terraform, kubectl). Wait for: ssh $TARGET cloud-init status --wait"
  exit 1
}
# The shared CCC scripts must know about CCC_TARGET (workshop/aks landing zone apply + 05-sync).
ssh "$TARGET" 'grep -q CCC_TARGET /opt/aks-ccc/40-setup-ccc-tests.sh' || {
  echo "The jumpbox's CCC scripts predate CCC_TARGET. From workshop/aks run:"
  echo "  (cd landing-zone && terraform apply) && ./scripts/05-sync-jumpbox.sh"
  exit 1
}

echo "==> Copying to $TARGET (~/aks-vanilla, /opt/aks-ccc/vanilla)"
ssh "$TARGET" 'mkdir -p ~/aks-vanilla && rm -rf /tmp/aks-vanilla-sync && mkdir -p /tmp/aks-vanilla-sync'
scp -q "$ROOT"/terraform/*.tf "$TARGET:aks-vanilla/"
ssh "$TARGET" 'umask 077; cat > ~/aks-vanilla/terraform.tfvars.json' <<<"$TFVARS"
scp -q -p "$ROOT"/scripts/{target.sh,10-build-cluster.sh,40-setup-ccc-tests.sh,50-run-ccc-tests.sh,90-destroy-cluster.sh,95-destroy-ccc-tests.sh} \
  "$TARGET:/tmp/aks-vanilla-sync/"
ssh "$TARGET" 'sudo mkdir -p /opt/aks-ccc/vanilla && sudo cp -p /tmp/aks-vanilla-sync/* /opt/aks-ccc/vanilla/ \
  && rm -rf /tmp/aks-vanilla-sync && ls -l ~/aks-vanilla /opt/aks-ccc/vanilla'
echo "Next, on the jumpbox: /opt/aks-ccc/vanilla/10-build-cluster.sh"
