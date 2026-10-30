#!/usr/bin/env bash
# Run ON THE JUMPBOX after 10-run-example.sh: /opt/aks-ccc/game-10-setup.sh
# TraderX hardening challenge (game format A, see workshop/aks/game/README.md).
#
# For each team (team-01 .. team-NN, GAME_TEAMS=4 by default):
#   - a namespace with Pod Security baseline, governance labels, a ResourceQuota
#     (GAME_TEAM_CPU / GAME_TEAM_MEMORY requests, one load balancer) and LimitRange defaults;
#   - the starter TraderX (/opt/aks-ccc/traderx.yaml, deliberately non-compliant)
#     and edge-proxy-public on a load balancer, published as team-NN.<APP_DNS_ZONE_NAME>;
#   - a ServiceAccount "player" with edit rights in its namespace only;
#   - a jumpbox login (user team-NN, password in ~/ccc-game/teams.tsv) whose kubectl
#     uses that ServiceAccount, with ~/traderx.yaml, ~/MISSION.md and game-status.
# Then it installs Audit+Warn copies of the six TraderX Kyverno policies scoped to
# the team namespaces (game-*), which the scoreboard (game-20-scoreboard.sh) reads.
#
# Rerunning is safe: it keeps the teams' work and passwords, and issues fresh
# kubectl tokens (valid GAME_TOKEN_HOURS). GAME_RESET=true deletes the team
# namespaces and starts every team from the starter again.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
GAME_TEAMS="${GAME_TEAMS:-4}"
GAME_RESET="${GAME_RESET:-false}"
GAME_DIR="${GAME_DIR:-$HOME/ccc-game}"
GAME_TOKEN_HOURS="${GAME_TOKEN_HOURS:-12}"
GAME_TEAM_CPU="${GAME_TEAM_CPU:-1200m}"
GAME_TEAM_MEMORY="${GAME_TEAM_MEMORY:-5Gi}"
FILES=/opt/aks-ccc
MANIFEST="${MANIFEST:-$FILES/traderx.yaml}"
GAME_LABEL_KEY=workshop.finos.org/game
GAME_LABEL="$GAME_LABEL_KEY=format-a"
TEAMS=()
for i in $(seq "$GAME_TEAMS"); do TEAMS+=("$(printf 'team-%02d' "$i")"); done
TEAMS_JSON="$(printf '%s\n' "${TEAMS[@]}" | jq -R . | jq -sc .)"

for f in "$MANIFEST" "$FILES/traderx-policies.yaml" "$FILES/kyverno-reports-rbac.yaml" "$FILES/game-mission.md" "$FILES/game-status.sh"; do
  [[ -f "$f" ]] || { echo "$f not found. From your laptop run workshop/aks/scripts/05-sync-jumpbox.sh, then rerun $0"; exit 1; }
done
[[ -n "${APP_DNS_ZONE_NAME:-}" && -n "${LB_ALLOWED_CIDRS:-}" ]] || {
  echo "env.sh has no APP_DNS_ZONE_NAME/LB_ALLOWED_CIDRS: apply the landing zone and run 05-sync-jumpbox.sh from your laptop."
  exit 1
}

az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"
CLUSTER_NAME="$(terraform -chdir="$EXAMPLE_DIR" output -raw cluster_name)"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
mkdir -p "$GAME_DIR"
chmod 700 "$GAME_DIR"

if kubectl get namespaces -o name | grep -q '^namespace/traderx-[0-9]'; then
  echo "WARNING: TraderX instances from 30-deploy-traderx.sh are running. The cluster is sized for"
  echo "         about 4 TraderX copies in total; delete them first: kubectl delete namespace traderx-1 ..."
fi

# The starter: the demo manifest for one team, without its Namespace object (the
# script owns the namespace and its labels; teams cannot edit namespaces).
starter() {
  awk 'BEGIN { RS = "\n---\n"; ORS = "\n---\n" } !/(^|\n)kind: Namespace(\n|$)/' "$MANIFEST" |
    sed -e "s/^  namespace: traderx$/  namespace: $1/"
}

if [[ "$GAME_RESET" == "true" ]]; then
  echo "==> GAME_RESET: deleting the team namespaces"
  kubectl delete namespace "${TEAMS[@]}" --ignore-not-found --wait
  rm -f "$GAME_DIR/game.json" "$GAME_DIR/scoreboard/state.json"
fi

for ns in "${TEAMS[@]}"; do
  echo "==> $ns"
  new=false
  kubectl get namespace "$ns" >/dev/null 2>&1 || new=true
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Pod Security baseline (CCC.K8S.CN11.AR01) and the governance labels game-governance-labels expects.
  kubectl label --overwrite namespace "$ns" "$GAME_LABEL" \
    pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest \
    app.kubernetes.io/name=traderx workshop.finos.org/owner="$ns" workshop.finos.org/environment=workshop \
    workshop.finos.org/data-classification=synthetic workshop.finos.org/policy-profile=ccc-k8s-workshop >/dev/null
  kubectl apply -f - >/dev/null <<EOF
# Keeps one team from starving the others on the shared nodes. Pods without
# requests get the LimitRange defaults, so the starter still schedules.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: game-quota
  namespace: $ns
spec:
  hard:
    requests.cpu: "$GAME_TEAM_CPU"
    requests.memory: "$GAME_TEAM_MEMORY"
    services.loadbalancers: "1"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: game-defaults
  namespace: $ns
spec:
  limits:
    - type: Container
      defaultRequest: { cpu: 25m, memory: 32Mi }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: player
  namespace: $ns
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: player-edit
  namespace: $ns
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: edit }
subjects: [{ kind: ServiceAccount, name: player, namespace: $ns }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: player-reports
  namespace: $ns
rules:
  - apiGroups: [wgpolicyk8s.io, openreports.io]
    resources: [policyreports, reports]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: player-reports
  namespace: $ns
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: player-reports }
subjects: [{ kind: ServiceAccount, name: player, namespace: $ns }]
---
apiVersion: v1
kind: Service
metadata:
  name: edge-proxy-public
  namespace: $ns
  labels:
    app: edge-proxy
  annotations:
    external-dns.kubernetes.io/hostname: $ns.$APP_DNS_ZONE_NAME
spec:
  type: LoadBalancer
  selector:
    app: edge-proxy
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
  loadBalancerSourceRanges: [${LB_ALLOWED_CIDRS//,/, }]
EOF
  if [[ "$new" == "true" ]]; then
    echo "    deploying the starter TraderX"
    starter "$ns" | kubectl apply -f - >/dev/null
  else
    echo "    namespace exists: keeping the team's work (GAME_RESET=true starts over)"
  fi
done

echo "==> Player access to the game policies (read-only)"
{
  cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ccc-game-player
  labels: { $GAME_LABEL_KEY: format-a }
rules:
  - apiGroups: [policies.kyverno.io]
    resources: [validatingpolicies]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ccc-game-player
  labels: { $GAME_LABEL_KEY: format-a }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: ccc-game-player }
subjects:
EOF
  for ns in "${TEAMS[@]}"; do echo "  - { kind: ServiceAccount, name: player, namespace: $ns }"; done
} | kubectl apply -f - >/dev/null

# Audit+Warn copies of examples/traderx/policies scoped to the team namespaces:
# nothing is blocked, kubectl apply prints each violation as a warning and Kyverno
# records pass/fail per Deployment in PolicyReports, which the scoreboard counts.
echo "==> Game policies (game-*: Audit + Warn in ${TEAMS[*]})"
kubectl apply -f "$FILES/kyverno-reports-rbac.yaml" >/dev/null
# The governance policy's owner label values become the facilitators plus these teams.
OLD_OWNERS="['facilitators', 'team-01', 'team-02', 'team-03', 'team-04', 'team-05']"
NEW_OWNERS="[$(printf "'%s', " facilitators "${TEAMS[@]}" | sed 's/, $//')]"
kubectl create --dry-run=client -o json -f "$FILES/traderx-policies.yaml" |
  jq -s --argjson teams "$TEAMS_JSON" --arg old "$OLD_OWNERS" --arg new "$NEW_OWNERS" '
    [.[] | if .kind == "List" then .items[] else . end] |
    {apiVersion: "v1", kind: "List", items: map(
      .metadata.name |= sub("^traderx-"; "game-")
      | .metadata.labels["workshop.finos.org/game"] = "format-a"
      | .spec.validationActions = ["Audit", "Warn"]
      | .spec.matchConstraints.namespaceSelector = {matchExpressions: [{key: "kubernetes.io/metadata.name", operator: "In", values: $teams}]}
      | .spec.validations |= map(.expression |= (split($old) | join($new)))
    )}' > "$GAME_DIR/game-policies.json"
grep -q "'${TEAMS[-1]}'" "$GAME_DIR/game-policies.json" ||
  { echo "Could not set the owner label values in the governance policy; check examples/traderx/policies"; exit 1; }
kubectl apply -f "$GAME_DIR/game-policies.json"
not_ready=""
for _ in $(seq 1 30); do
  not_ready="$(kubectl get vpol -l "$GAME_LABEL" -o json | jq -r '.items[] | select(.status.conditionStatus.ready != true) | .metadata.name')"
  [[ -z "$not_ready" ]] && break
  sleep 10
done
kubectl get vpol -l "$GAME_LABEL"
[[ -z "$not_ready" ]] || { echo "Game policies not ready: $not_ready"; exit 1; }

echo "==> Jumpbox logins"
PASSWORDS="$GAME_DIR/teams.tsv"
(umask 077; touch "$PASSWORDS")
SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
sudo install -m 0755 "$FILES/game-status.sh" /usr/local/bin/game-status
if ! command -v crane >/dev/null; then
  # Lets teams look up image digests: crane digest docker.io/library/nginx:1.27-alpine
  curl -fsSL https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz |
    sudo tar -xz -C /usr/local/bin crane
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for ns in "${TEAMS[@]}"; do
  id "$ns" >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash "$ns"
  pw="$(awk -v t="$ns" '$1 == t { print $2 }' "$PASSWORDS")"
  if [[ -z "$pw" ]]; then
    pw="$(openssl rand -hex 6)"
    printf '%s\t%s\n' "$ns" "$pw" >> "$PASSWORDS"
  fi
  echo "$ns:$pw" | sudo chpasswd
  home="$(getent passwd "$ns" | cut -d: -f6)"
  token="$(kubectl -n "$ns" create token player --duration="${GAME_TOKEN_HOURS}h")"
  cat > "$tmp/config" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: $CLUSTER_NAME
    cluster: { server: "$SERVER", certificate-authority-data: "$CA_DATA" }
users:
  - name: $ns-player
    user: { token: "$token" }
contexts:
  - name: $ns
    context: { cluster: $CLUSTER_NAME, user: $ns-player, namespace: $ns }
current-context: $ns
EOF
  sudo install -D -m 0600 -o "$ns" -g "$ns" "$tmp/config" "$home/.kube/config"
  if [[ "$GAME_RESET" == "true" ]] || ! sudo test -f "$home/traderx.yaml"; then
    starter "$ns" > "$tmp/traderx.yaml"
    sudo install -m 0644 -o "$ns" -g "$ns" "$tmp/traderx.yaml" "$home/traderx.yaml"
  fi
  sed -e "s|__TEAM__|$ns|g" -e "s|__APP_HOST__|$ns.$APP_DNS_ZONE_NAME|g" \
    -e "s|__CPU__|$GAME_TEAM_CPU|g" -e "s|__MEMORY__|$GAME_TEAM_MEMORY|g" "$FILES/game-mission.md" > "$tmp/MISSION.md"
  sudo install -m 0644 -o "$ns" -g "$ns" "$tmp/MISSION.md" "$home/MISSION.md"
  sudo grep -q 'ccc-game' "$home/.bashrc" ||
    printf '\n# ccc-game\necho "Team %s: read ~/MISSION.md, check your progress with game-status."\n' "$ns" |
    sudo tee -a "$home/.bashrc" >/dev/null
done
# Password logins for the team users only (azureuser stays key-only). The NSG still
# limits SSH to admin_ssh_source_cidr. game-90-teardown.sh removes this block.
if ! sudo grep -q '^# BEGIN ccc-game' /etc/ssh/sshd_config; then
  printf '\n# BEGIN ccc-game\nMatch User team-*\n    PasswordAuthentication yes\n# END ccc-game\n' |
    sudo tee -a /etc/ssh/sshd_config >/dev/null
  sudo sshd -t
  sudo systemctl reload ssh
fi

# Game state for the scoreboard: teams, the Deployments every team must harden,
# and the policy order. The start time survives reruns (GAME_RESET resets it).
DEPLOYMENTS="$(starter "${TEAMS[0]}" | kubectl create --dry-run=client -o json -f - |
  jq -sc '[.[] | if .kind == "List" then .items[] else . end | select(.kind == "Deployment") | .metadata.name]')"
POLICIES="$(jq -c '[.items[].metadata.name]' "$GAME_DIR/game-policies.json")"
STARTED="$(jq -r '.started // empty' "$GAME_DIR/game.json" 2>/dev/null || true)"
jq -n --argjson teams "$TEAMS_JSON" --argjson deployments "$DEPLOYMENTS" --argjson policies "$POLICIES" \
  --arg zone "$APP_DNS_ZONE_NAME" --arg started "${STARTED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
  '{teams: $teams, deployments: $deployments, policies: $policies, zone: $zone, started: $started}' > "$GAME_DIR/game.json"

failed=()
for ns in "${TEAMS[@]}"; do
  echo "==> $ns: waiting for deployments"
  kubectl -n "$ns" wait deployment --all --for=condition=Available --timeout=15m >/dev/null || failed+=("$ns")
done
echo "==> Waiting up to 5 minutes for the team DNS names"
for _ in $(seq 60); do
  ok=0
  for ns in "${TEAMS[@]}"; do
    ip="$(kubectl -n "$ns" get svc edge-proxy-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    [[ -n "$ip" && "$(dig +short "$ns.$APP_DNS_ZONE_NAME" | tail -1)" == "$ip" ]] && ok=$((ok + 1))
  done
  ((ok == ${#TEAMS[@]})) && break
  sleep 5
done

JUMPBOX_IP="${LB_ALLOWED_CIDRS##*,}" # env.sh lists the jumpbox's public IP last
JUMPBOX_IP="${JUMPBOX_IP%/32}"
echo
printf '%-8s %-30s %-14s %-16s %s\n' TEAM LOGIN PASSWORD LB_IP APP
for ns in "${TEAMS[@]}"; do
  ip="$(kubectl -n "$ns" get svc edge-proxy-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  printf '%-8s %-30s %-14s %-16s %s\n' "$ns" "ssh $ns@$JUMPBOX_IP" "$(awk -v t="$ns" '$1 == t { print $2 }' "$PASSWORDS")" \
    "${ip:--}" "http://$ns.$APP_DNS_ZONE_NAME/"
done
cat <<EOF

Passwords: $PASSWORDS. kubectl tokens expire in ${GAME_TOKEN_HOURS}h; rerun this script to renew them.
Scoreboard: from your laptop run workshop/aks/game/25-scoreboard-from-laptop.sh
            (or here: /opt/aks-ccc/game-20-scoreboard.sh, served on 127.0.0.1:8088).
Teams browse their TraderX at http://<LB_IP>/ from addresses in LB_ALLOWED_CIDRS.
EOF
if ((${#failed[@]})); then
  echo "Starter deployments not ready in: ${failed[*]} (kubectl -n <team> get pods)."
  exit 1
fi
