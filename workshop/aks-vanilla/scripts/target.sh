# Sourced on the jumpbox (as /opt/aks-ccc/vanilla/target.sh) by the vanilla scripts and
# by the shared CCC scripts when CCC_TARGET=vanilla. Points them at the plain AVM
# cluster instead of the hardened workshop cluster.
export EXAMPLE_DIR="$HOME/aks-vanilla"
export CCC_WORK_DIR="$HOME/ccc-tests-vanilla"
export CCC_FQDN_OUTPUT=api_server_fqdn
export CCC_VERIFY_HINT=/opt/aks-ccc/vanilla/10-build-cluster.sh
export CCC_SETUP_HINT=/opt/aks-ccc/vanilla/40-setup-ccc-tests.sh
export CCC_LAPTOP_RUN_HINT="workshop/aks-vanilla/scripts/55-run-ccc-tests-from-laptop.sh"
export CCC_JUMPBOX_RUN_HINT=/opt/aks-ccc/vanilla/50-run-ccc-tests.sh
# The dashboard's notes explain the hardened workshop's low-cost settings; they do not apply here.
export CCC_DASHBOARD_ARGS=--no-workshop-notes
# The example creates its own resource group; the landing zone's RESOURCE_GROUP does not apply.
RESOURCE_GROUP="$(terraform -chdir="$EXAMPLE_DIR" output -raw resource_group_name 2>/dev/null || true)"
export RESOURCE_GROUP
