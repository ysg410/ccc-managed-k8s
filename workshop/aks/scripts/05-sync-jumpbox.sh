#!/usr/bin/env bash
# Run on your laptop after `terraform apply` in landing-zone. Copies the current
# env.sh, example tfvars, scripts and TraderX manifest to /opt/aks-ccc on the
# existing jumpbox (cloud-init only delivered them on first boot).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/landing-zone/generated/jumpbox"

[[ -d "$SRC" ]] || { echo "$SRC not found; run terraform apply in landing-zone first"; exit 1; }
TARGET="$(terraform -chdir="$ROOT/landing-zone" output -raw jumpbox_ssh | awk '{print $2}')"

echo "==> Copying $SRC to $TARGET:/opt/aks-ccc"
ssh "$TARGET" 'rm -rf /tmp/aks-ccc-sync'
scp -q -p -r "$SRC" "$TARGET:/tmp/aks-ccc-sync"
ssh "$TARGET" 'sudo cp -p /tmp/aks-ccc-sync/* /opt/aks-ccc/ && rm -rf /tmp/aks-ccc-sync && ls -l /opt/aks-ccc'
