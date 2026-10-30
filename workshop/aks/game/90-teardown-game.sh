#!/usr/bin/env bash
# Run ON THE JUMPBOX after the game: /opt/aks-ccc/game-90-teardown.sh
# Deletes the team namespaces (and their load balancers), the game-* policies and
# player RBAC, the team-NN jumpbox users and their password logins. Keeps the
# scoreboard history in ~/ccc-game/scoreboard. Run it before 90-destroy-example.sh.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
GAME_DIR="${GAME_DIR:-$HOME/ccc-game}"
GAME_LABEL=workshop.finos.org/game=format-a

az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"
CLUSTER_NAME="$(terraform -chdir="$EXAMPLE_DIR" output -raw cluster_name)"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing >/dev/null
kubelogin convert-kubeconfig -l azurecli

echo "==> Team namespaces, game policies and player RBAC"
kubectl delete namespace -l "$GAME_LABEL" --wait
kubectl delete validatingpolicies.policies.kyverno.io,clusterrolebinding,clusterrole -l "$GAME_LABEL"

echo "==> Jumpbox team users"
for u in $(getent passwd | cut -d: -f1 | grep -E '^team-[0-9]{2}$' || true); do
  sudo pkill -u "$u" || true
  sudo userdel --remove "$u" 2>/dev/null || sudo userdel "$u"
  echo "removed $u"
done
if sudo grep -q '^# BEGIN ccc-game' /etc/ssh/sshd_config; then
  sudo sed -i '/^# BEGIN ccc-game$/,/^# END ccc-game$/d' /etc/ssh/sshd_config
  sudo sshd -t
  sudo systemctl reload ssh
fi
rm -f "$GAME_DIR/teams.tsv" "$GAME_DIR/game-policies.json" "$GAME_DIR/game.json" "$GAME_DIR/scoreboard/state.json"
echo "Game removed. Scoreboard history: $GAME_DIR/scoreboard/history.csv"
