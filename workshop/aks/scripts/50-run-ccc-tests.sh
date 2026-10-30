#!/usr/bin/env bash
# Run ON THE JUMPBOX after 40-setup-ccc-tests.sh: /opt/aks-ccc/50-run-ccc-tests.sh
# (55-run-ccc-tests-from-laptop.sh calls it through an SSH tunnel.)
#
# Renders the Privateer config for the current cluster, runs the CCC behavioural
# tests (cfi-testing/run-compliance-tests.sh -> pvtr -> ccc-behavioural-plugin)
# and builds the compliance dashboard. Results: ~/ccc-tests/results/<UTC time>/
#   dashboard.html          one-page CCC compliance summary
#   html/, ocsf/            the runner's detailed HTML and OCSF reports
#   privateer-config.yml    the config used (no secrets), run.log
#
# Optional: CCC_TAGS='@CCC.K8S.CN06' (extra Cucumber tag filter), CCC_TIMEOUT=60m,
# CCC_DEBUG=1 (run the plugin in-process without pvtr, as upstream CI does).
# CCC_TARGET=vanilla tests the plain AVM cluster from workshop/aks-vanilla.
set -uo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
# shellcheck source=/dev/null
[[ "${CCC_TARGET:-aks}" == aks ]] || source "/opt/aks-ccc/$CCC_TARGET/target.sh"
WORK_DIR="${CCC_WORK_DIR:-$HOME/ccc-tests}"
ENV_FILE="$WORK_DIR/ccc-test-env.sh"
TUNNEL_PORT=18080 # 55-run-ccc-tests-from-laptop.sh forwards the laptop observer here
TLS_PORT=18443    # socat terminates TLS here (the plugin only calls HTTPS observers)
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
SETUP_HINT="${CCC_SETUP_HINT:-/opt/aks-ccc/40-setup-ccc-tests.sh}"

[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found. Run $SETUP_HINT first."; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

# The plugin authenticates with DefaultAzureCredential: use only your az login.
unset AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_CLIENT_CERTIFICATE_PATH AZURE_USERNAME AZURE_PASSWORD AZURE_FEDERATED_TOKEN_FILE
export AZURE_TOKEN_CREDENTIALS=dev AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" AZURE_TENANT_ID="$TENANT_ID"
az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null || exit 1
az account set --subscription "$SUBSCRIPTION_ID" || exit 1

tf_out() { terraform -chdir="$EXAMPLE_DIR" output -raw "$1"; }
export LOCATION RESOURCE_GROUP SUBSCRIPTION_ID TENANT_ID WI_STORAGE_ACCOUNT
export CLUSTER_NAME PRIVATE_FQDN OIDC_ISSUER_URL LOG_ANALYTICS_WORKSPACE_GUID
CLUSTER_NAME="$(tf_out cluster_name)" || exit 1
# The API server FQDN the CN01 reachability probe targets (public for the vanilla cluster).
PRIVATE_FQDN="$(tf_out "${CCC_FQDN_OUTPUT:-private_fqdn}")"
OIDC_ISSUER_URL="$(tf_out oidc_issuer_url)"
LOG_ANALYTICS_WORKSPACE_GUID="$(az monitor log-analytics workspace show --ids "$(tf_out log_analytics_workspace_id)" --query customerId -o tsv)"

getent hosts "$PRIVATE_FQDN" >/dev/null || { echo "$PRIVATE_FQDN does not resolve. Run ${CCC_VERIFY_HINT:-/opt/aks-ccc/10-run-example.sh} first."; exit 1; }
# 40-setup-ccc-tests.sh fetched this cluster's credentials; make sure kubectl and the plugin use them.
kubectl config use-context "$CLUSTER_NAME" >/dev/null || { echo "No kubeconfig context $CLUSTER_NAME. Run $SETUP_HINT first."; exit 1; }
kubectl get namespace ccc-test >/dev/null 2>&1 || { echo "Fixtures missing. Run $SETUP_HINT first."; exit 1; }

export REACHABILITY_PROBE_MODE REACHABILITY_PROBE_URL REACHABILITY_PROBE_OBSERVER REACHABILITY_PROBE_SHARED_SECRET
if curl -fsS -m 5 "http://127.0.0.1:$TUNNEL_PORT/healthz" >/dev/null 2>&1 && [[ -f "$WORK_DIR/reachability-secret" ]]; then
  socat "OPENSSL-LISTEN:$TLS_PORT,bind=127.0.0.1,reuseaddr,fork,cert=$WORK_DIR/tunnel.crt,key=$WORK_DIR/tunnel.key,verify=0" \
    "TCP:127.0.0.1:$TUNNEL_PORT" &
  SOCAT_PID=$!
  trap 'kill "$SOCAT_PID" 2>/dev/null' EXIT
  sleep 1
  curl -fsS -m 5 "https://localhost:$TLS_PORT/healthz" >/dev/null || { echo "TLS relay to the laptop observer failed"; exit 1; }
  REACHABILITY_PROBE_MODE=remote
  REACHABILITY_PROBE_URL="https://localhost:$TLS_PORT"
  REACHABILITY_PROBE_OBSERVER=laptop-internet
  REACHABILITY_PROBE_SHARED_SECRET="$(cat "$WORK_DIR/reachability-secret")"
  echo "Untrusted-network probe: laptop observer through the SSH tunnel"
else
  REACHABILITY_PROBE_MODE=local REACHABILITY_PROBE_URL="" REACHABILITY_PROBE_OBSERVER=jumpbox REACHABILITY_PROBE_SHARED_SECRET=""
  echo "NOTE: no laptop observer; CCC.K8S.CN01 probes the API from the jumpbox (inside the approved network)."
fi

OUT="$WORK_DIR/results/$(date -u +%Y%m%dT%H%M%SZ)"
CONFIG="$OUT/privateer-config.yml"
mkdir -p "$OUT"
# Only the cluster coordinates are filled in; ${AZURE_TEST_USER_*} and the
# observer secret are expanded by the plugin at runtime.
envsubst '${LOCATION} ${CLUSTER_NAME} ${SUBSCRIPTION_ID} ${TENANT_ID} ${RESOURCE_GROUP} ${PRIVATE_FQDN} ${OIDC_ISSUER_URL} ${LOG_ANALYTICS_WORKSPACE_GUID} ${WI_STORAGE_ACCOUNT} ${REACHABILITY_PROBE_MODE} ${REACHABILITY_PROBE_URL} ${REACHABILITY_PROBE_OBSERVER}' \
  < /opt/aks-ccc/ccc-privateer-config.yml.tmpl > "$CONFIG"

ARGS=(-c "$CONFIG" -S azureKubernetes -s kubernetes -o "$OUT" -t "${CCC_TIMEOUT:-60m}")
[[ -n "${CCC_TAGS:-}" ]] && ARGS+=(-g "$CCC_TAGS")
[[ "${CCC_DEBUG:-0}" == "1" ]] && ARGS+=(--debug)
echo "==> Running CCC behavioural tests against $CLUSTER_NAME (output: $OUT)"
echo "    The first run compiles the CCC Go modules: 15-30 min on the 4 GB jumpbox, with long"
echo "    silent stretches while it swaps. Later runs reuse the Go build cache (a minute or two)."
(cd "$OUT" && "$CCC_DIR/cfi-testing/run-compliance-tests.sh" "${ARGS[@]}") 2>&1 | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}
ln -sfn "$OUT" "$WORK_DIR/results/latest"

echo "==> Dashboard"
# shellcheck disable=SC2086 # CCC_DASHBOARD_ARGS holds separate flags
python3 /opt/aks-ccc/ccc-dashboard.py --results "$OUT" --config "$CONFIG" \
  --catalogs "$CCC_DIR/website/src/data/ccc-releases" ${CCC_DASHBOARD_ARGS:-} || echo "Dashboard failed; see $OUT/run.log"

cat <<EOF

Test run exit code: $rc (non-zero when any scenario fails).
Results: $OUT
Copy them to your laptop (55-run-ccc-tests-from-laptop.sh does this for you):
  scp -r azureuser@<jumpbox-ip>:$OUT ./ccc-results/
Note: CCC.Core.CN04 / CCC.K8S.CN14 add the tag ccc_compliance_test to the cluster. The
example's next terraform plan removes it (expected drift).
EOF
exit "$rc"
