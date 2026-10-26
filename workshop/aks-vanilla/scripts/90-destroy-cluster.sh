#!/usr/bin/env bash
# Run ON THE JUMPBOX to remove the plain AVM cluster and its resource group:
#   /opt/aks-ccc/vanilla/90-destroy-cluster.sh
# Run /opt/aks-ccc/vanilla/95-destroy-ccc-tests.sh first if you set up the CCC tests.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
# shellcheck source=/dev/null
source /opt/aks-ccc/vanilla/target.sh
if [[ -f "$CCC_WORK_DIR/ccc-test-env.sh" ]]; then
  echo "CCC test fixtures still exist; run /opt/aks-ccc/vanilla/95-destroy-ccc-tests.sh first."
  exit 1
fi
az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"
cd "$EXAMPLE_DIR"
terraform destroy
