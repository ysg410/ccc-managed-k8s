#!/usr/bin/env bash
# Run ON THE JUMPBOX after 20-verify-cluster.sh: /opt/aks-ccc/40-setup-ccc-tests.sh
# Prepares the CCC behavioural tests (FINOS common-cloud-controls, Privateer +
# ccc-behavioural-plugin) against the workshop cluster. Safe to rerun.
#
#   1. Toolchain: Go (version from the CCC repo's go.work), Node 22, pvtr
#      (Privateer), ko, socat, envsubst; a 4 GB swap file for the Go build.
#   2. CCC repo (CCC_REPO_URL / CCC_REPO_BRANCH) in ~/common-cloud-controls and
#      its DEV catalogs (npm run generate:catalogs).
#   3. Azure test fixtures in the cluster's resource group:
#        - Entra app + service principal with NO role assignments
#          (test-user-no-access, used by CCC.Core.CN05.AR06 and CCC.K8S.CN15.AR02);
#        - user-assigned identity federated to ccc-test/ccc-wi-sa, with
#          Storage Blob Data Reader on a small storage account holding
#          probe/probe.txt (CCC.K8S.CN03.AR01).
#   4. In-cluster fixtures (ccc-k8s-fixtures.yaml) and the admission-webhook
#      probe (ccc-webhook-probe.yaml; image built with ko, pushed to the
#      workshop registry).
#   5. A localhost TLS certificate for the reachability observer tunnel
#      (55-run-ccc-tests-from-laptop.sh).
#
# Writes ~/ccc-tests/ccc-test-env.sh (mode 0600, holds the service principal
# secret). Remove everything with 95-destroy-ccc-tests.sh.
#
# CCC_TARGET=vanilla targets the plain AVM cluster from workshop/aks-vanilla
# instead (/opt/aks-ccc/vanilla/target.sh sets its Terraform directory, resource
# group and ~/ccc-tests-vanilla work directory).
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
# shellcheck source=/dev/null
[[ "${CCC_TARGET:-aks}" == aks ]] || source "/opt/aks-ccc/$CCC_TARGET/target.sh"
CCC_REPO_URL="${CCC_REPO_URL:-https://github.com/finos/common-cloud-controls.git}"
CCC_REPO_BRANCH="${CCC_REPO_BRANCH:-managed-k8s-behavioural}"
CCC_DIR="${CCC_DIR:-$HOME/common-cloud-controls}"
WORK_DIR="${CCC_WORK_DIR:-$HOME/ccc-tests}"
ENV_FILE="$WORK_DIR/ccc-test-env.sh"
FILES=/opt/aks-ccc
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
TAGS=(environment=test owner=ccc-workshop data-classification=internal purpose=ccc-behavioural-tests)

step() { echo; echo "==> $*"; }
mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

step "OS packages and swap"
sudo apt-get update -qq
sudo apt-get install -y -qq gettext-base socat python3-yaml openssl >/dev/null
if [[ -z "$(swapon --show)" ]]; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

step "CCC repository: $CCC_REPO_URL ($CCC_REPO_BRANCH)"
if [[ -d "$CCC_DIR/.git" ]]; then
  git -C "$CCC_DIR" fetch --quiet origin "$CCC_REPO_BRANCH"
  git -C "$CCC_DIR" checkout --quiet "$CCC_REPO_BRANCH"
  git -C "$CCC_DIR" pull --quiet --ff-only origin "$CCC_REPO_BRANCH"
else
  git clone --quiet --branch "$CCC_REPO_BRANCH" "$CCC_REPO_URL" "$CCC_DIR"
fi
git -C "$CCC_DIR" log --oneline -1

step "Go, Node.js, Privateer (pvtr) and ko"
GO_VERSION="$(awk '$1 == "go" { print $2; exit }' "$CCC_DIR/modules/go.work")"
if [[ "$(/usr/local/go/bin/go env GOVERSION 2>/dev/null || true)" != "go$GO_VERSION" ]]; then
  sudo rm -rf /usr/local/go
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" | sudo tar -C /usr/local -xz
fi
if ! node --version 2>/dev/null | grep -Eq '^v(2[2-9]|[3-9][0-9])\.'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs >/dev/null
fi
# The CLI lives in github.com/privateerproj/pvtr; its installer verifies the release checksum.
# (The CCC README's `go install .../privateer/cmd/pvtr` path no longer exists.)
if ! command -v pvtr >/dev/null; then
  mkdir -p "$HOME/go/bin"
  curl -fsSL https://raw.githubusercontent.com/privateerproj/pvtr/main/install.sh | bash -s -- -p "$HOME/go/bin" -y
fi
command -v ko >/dev/null || GOWORK=off go install github.com/google/ko@latest
echo "$(go version) | node $(node --version) | pvtr $(command -v pvtr) | ko $(ko version 2>/dev/null)"
grep -q '/usr/local/go/bin' "$HOME/.bashrc" || echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >> "$HOME/.bashrc"

step "CCC catalogs (DEV)"
HEAD="$(git -C "$CCC_DIR" rev-parse HEAD)"
if [[ ! -f "$CCC_DIR/website/src/data/ccc-releases/CCC.K8S_DEV-controls.yaml" || "$(cat "$WORK_DIR/.catalogs-head" 2>/dev/null)" != "$HEAD" ]]; then
  (cd "$CCC_DIR" && npm ci --prefix website --no-audit --no-fund --loglevel=error && npm run generate:catalogs --prefix website)
  echo "$HEAD" > "$WORK_DIR/.catalogs-head"
fi
ls "$CCC_DIR/website/src/data/ccc-releases/" | grep -E 'CCC\.(K8S|Core)_.*-controls\.yaml'

step "Cluster access"
az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"
tf_out() { terraform -chdir="$EXAMPLE_DIR" output -raw "$1"; }
CLUSTER_NAME="$(tf_out cluster_name)"
OIDC_ISSUER_URL="$(tf_out oidc_issuer_url)"
ACR_LOGIN_SERVER="$(tf_out container_registry_login_server)"
SUFFIX="$(tr -cd 'a-z0-9' <<<"${CLUSTER_NAME##*-}")"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing >/dev/null
kubelogin convert-kubeconfig -l azurecli
kubectl get --raw /readyz >/dev/null || { echo "kubectl cannot reach $CLUSTER_NAME. Run ${CCC_VERIFY_HINT:-/opt/aks-ccc/20-verify-cluster.sh} first."; exit 1; }
echo "Cluster: $CLUSTER_NAME, registry: $ACR_LOGIN_SERVER"

# Saved after each fixture so a failed run keeps the service principal secret.
write_env() {
  (
    umask 077
    {
      echo "# Written by 40-setup-ccc-tests.sh. Holds a service principal secret: do not share."
      printf 'export CCC_DIR=%q\n' "$CCC_DIR"
      printf 'export AZURE_TEST_USER_NO_ACCESS_USER_NAME=%q\n' "$SP_NAME"
      printf 'export AZURE_TEST_USER_NO_ACCESS_CLIENT_ID=%q\n' "${AZURE_TEST_USER_NO_ACCESS_CLIENT_ID:-}"
      printf 'export AZURE_TEST_USER_NO_ACCESS_CLIENT_SECRET=%q\n' "${AZURE_TEST_USER_NO_ACCESS_CLIENT_SECRET:-}"
      printf 'export AZURE_TEST_USER_NO_ACCESS_OBJECT_ID=%q\n' "${AZURE_TEST_USER_NO_ACCESS_OBJECT_ID:-}"
      printf 'export WI_NAME=%q\n' "$WI_NAME"
      printf 'export WI_CLIENT_ID=%q\n' "${WI_CLIENT_ID:-}"
      printf 'export WI_STORAGE_ACCOUNT=%q\n' "$WI_STORAGE_ACCOUNT"
    } > "$ENV_FILE"
  )
}
# New Entra principals take a minute or two to replicate; retry lookups until they resolve.
retry() {
  local i
  for i in $(seq 1 12); do
    "$@" && return 0
    echo "  waiting for Entra ID replication ($i/12)..." >&2
    sleep 10
  done
  return 1
}
# Count role assignments by principal ID (avoids --assignee's Graph lookup).
role_count() {
  az role assignment list --all --query "[?principalId=='$1'${2:+ && scope=='$2'}${3:+ && roleDefinitionName=='$3'}] | length(@)" -o tsv
}

SP_NAME="sp-ccc-tests-no-access-$SUFFIX"
WI_NAME="id-ccc-tests-wi-$SUFFIX"
WI_STORAGE_ACCOUNT="stcccwi$SUFFIX"
# Reuse the saved service principal secret if there is one; otherwise create one.
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

step "Test identity without access (Entra service principal, no role assignments)"
if [[ -z "${AZURE_TEST_USER_NO_ACCESS_CLIENT_SECRET:-}" ]] || ! az ad sp show --id "${AZURE_TEST_USER_NO_ACCESS_CLIENT_ID:-none}" -o none 2>/dev/null; then
  # Reuses the app if it already exists (from an earlier, interrupted run) and issues a new secret.
  SP_JSON="$(az ad sp create-for-rbac --display-name "$SP_NAME" --years 1 -o json)"
  AZURE_TEST_USER_NO_ACCESS_CLIENT_ID="$(jq -r .appId <<<"$SP_JSON")"
  AZURE_TEST_USER_NO_ACCESS_CLIENT_SECRET="$(jq -r .password <<<"$SP_JSON")"
  unset SP_JSON
  [[ -n "$AZURE_TEST_USER_NO_ACCESS_CLIENT_SECRET" && "$AZURE_TEST_USER_NO_ACCESS_CLIENT_SECRET" != null ]] \
    || { echo "Creating $SP_NAME returned no secret"; exit 1; }
  write_env
fi
AZURE_TEST_USER_NO_ACCESS_OBJECT_ID="$(retry az ad sp show --id "$AZURE_TEST_USER_NO_ACCESS_CLIENT_ID" --query id -o tsv)"
write_env
ROLE_COUNT="$(role_count "$AZURE_TEST_USER_NO_ACCESS_OBJECT_ID")"
echo "$SP_NAME: appId $AZURE_TEST_USER_NO_ACCESS_CLIENT_ID, role assignments: $ROLE_COUNT"
[[ "$ROLE_COUNT" == "0" ]] || echo "WARNING: test-user-no-access must have no role assignments; remove them."

step "Workload identity probe: managed identity, federated credential, storage account"
setup_workload_identity_probe() {
az identity create -g "$RESOURCE_GROUP" -n "$WI_NAME" -l "$LOCATION" --tags "${TAGS[@]}" -o none
WI_CLIENT_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$WI_NAME" --query clientId -o tsv)"
WI_PRINCIPAL_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$WI_NAME" --query principalId -o tsv)"
write_env
az identity federated-credential create -g "$RESOURCE_GROUP" --identity-name "$WI_NAME" --name ccc-wi-sa \
  --issuer "$OIDC_ISSUER_URL" --subject system:serviceaccount:ccc-test:ccc-wi-sa \
  --audiences api://AzureADTokenExchange -o none
if ! az storage account show -g "$RESOURCE_GROUP" -n "$WI_STORAGE_ACCOUNT" -o none 2>/dev/null; then
  az storage account create -g "$RESOURCE_GROUP" -n "$WI_STORAGE_ACCOUNT" -l "$LOCATION" --sku Standard_LRS \
    --kind StorageV2 --min-tls-version TLS1_2 --https-only true --allow-blob-public-access false \
    --tags "${TAGS[@]}" -o none
fi
# The fixture blob is uploaded with the account key; the probe reads it with Entra (--auth-mode login).
az storage container create --account-name "$WI_STORAGE_ACCOUNT" -n probe --auth-mode key -o none
az storage blob upload --account-name "$WI_STORAGE_ACCOUNT" -c probe -n probe.txt --data ccc-wi-probe-ok \
  --overwrite --auth-mode key -o none
STORAGE_ID="$(az storage account show -g "$RESOURCE_GROUP" -n "$WI_STORAGE_ACCOUNT" --query id -o tsv)"
if [[ "$(role_count "$WI_PRINCIPAL_ID" "$STORAGE_ID" "Storage Blob Data Reader")" == "0" ]]; then
  retry az role assignment create --assignee-object-id "$WI_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" --scope "$STORAGE_ID" -o none
fi
echo "$WI_NAME (client $WI_CLIENT_ID) can read $WI_STORAGE_ACCOUNT/probe/probe.txt"
}
if [[ -n "$OIDC_ISSUER_URL" ]]; then
  setup_workload_identity_probe
else
  # A cluster without an OIDC issuer cannot federate service accounts: CCC.K8S.CN03.AR01 fails.
  echo "No OIDC issuer on $CLUSTER_NAME: skipping the workload identity probe (CCC.K8S.CN03.AR01 will fail)."
  WI_CLIENT_ID="" WI_STORAGE_ACCOUNT=""
  write_env
fi
echo "Saved $ENV_FILE"

step "In-cluster fixtures"
kubectl apply -f "$FILES/ccc-k8s-fixtures.yaml"
[[ -z "$WI_CLIENT_ID" ]] || kubectl -n ccc-test annotate serviceaccount ccc-wi-sa "azure.workload.identity/client-id=$WI_CLIENT_ID" --overwrite
kubectl -n ccc-network-control wait deployment --all --for=condition=Available --timeout=5m
kubectl -n ccc-test wait deployment --all --for=condition=Available --timeout=5m

step "Admission webhook probe (CN11.AR03)"
deploy_webhook_probe() {
  local tls="$WORK_DIR/webhook-tls" svc=ccc-admission-webhook-probe ns=ccc-admission-webhook-probe image token
  mkdir -p "$tls"
  if [[ ! -f "$tls/tls.crt" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$tls/tls.key" -out "$tls/tls.crt" \
      -subj "/O=FINOS CCC/CN=$svc.$ns.svc" \
      -addext "subjectAltName=DNS:$svc,DNS:$svc.$ns,DNS:$svc.$ns.svc,DNS:$svc.$ns.svc.cluster.local" \
      -addext "extendedKeyUsage=serverAuth" 2>/dev/null || return 1
  fi
  token="$(az acr login -n "${ACR_LOGIN_SERVER%%.*}" --expose-token --query accessToken -o tsv 2>/dev/null)" || return 1
  ko login "$ACR_LOGIN_SERVER" -u 00000000-0000-0000-0000-000000000000 --password-stdin <<<"$token" || return 1
  image="$(cd "$CCC_DIR/modules/probes/admission-webhook" && GOWORK=off KO_DOCKER_REPO="$ACR_LOGIN_SERVER/$svc" \
    ko build --bare --sbom=none --platform=linux/amd64 .)" || return 1
  echo "Image: $image"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - || return 1
  kubectl -n "$ns" create secret tls "$svc-tls" --cert="$tls/tls.crt" --key="$tls/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f - || return 1
  sed -e "s|__PROBE_IMAGE__|$image|" -e "s|__CA_BUNDLE__|$(base64 -w0 "$tls/tls.crt")|" \
    "$FILES/ccc-webhook-probe.yaml" | kubectl apply -f - || return 1
  kubectl -n "$ns" rollout status deployment "$svc" --timeout=5m
}
if ! deploy_webhook_probe; then
  echo "WARNING: the webhook probe is not deployed, so CCC.K8S.CN11.AR03 will fail. Pushing to"
  echo "         $ACR_LOGIN_SERVER needs AcrPush (or Owner/Contributor) for $(az account show --query user.name -o tsv)."
fi

step "Localhost certificate for the reachability observer tunnel"
# One per work directory, so each target has its own key.
TUNNEL_CA="/usr/local/share/ca-certificates/ccc-reachability-tunnel-$(basename "$WORK_DIR").crt"
if [[ ! -f "$WORK_DIR/tunnel.key" || ! -f "$TUNNEL_CA" ]]; then
  (umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$WORK_DIR/tunnel.key" \
    -out "$WORK_DIR/tunnel.crt" -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null)
  sudo cp "$WORK_DIR/tunnel.crt" "$TUNNEL_CA"
  sudo update-ca-certificates >/dev/null
fi
echo "Trusted: $TUNNEL_CA"

cat <<EOF

CCC test setup complete. Next, from your laptop (recommended, probes the API from an untrusted network):
  ${CCC_LAPTOP_RUN_HINT:-./scripts/55-run-ccc-tests-from-laptop.sh}
or here on the jumpbox (CCC.K8S.CN01 then probes from inside the approved network):
  ${CCC_JUMPBOX_RUN_HINT:-/opt/aks-ccc/50-run-ccc-tests.sh}
EOF
