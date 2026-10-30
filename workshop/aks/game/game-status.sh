#!/usr/bin/env bash
# For teams (installed as /usr/local/bin/game-status on the jumpbox):
#   game-status               your score per policy and every failing check
#   game-status <deployment>  only that Deployment
# Kyverno updates the results a few seconds after each kubectl apply.
set -euo pipefail
ns="$(kubectl config view --minify -o jsonpath='{..namespace}')"
deploy="${1:-}"
kubectl get policyreports.wgpolicyk8s.io -o json | jq -r --arg d "$deploy" --arg ns "${ns:-default}" '
  [.items[] | select(.scope.kind == "Deployment" and ($d == "" or .scope.name == $d))
   | .scope.name as $n | .results[]? | {d: $n, p: .policy, r: .result, m: (.message // "")}] as $all
  | "Policy results in \($ns)\(if $d != "" then " for " + $d else "" end):",
    ($all | group_by(.p)[] | "  \(.[0].p): \(map(select(.r == "pass" or .r == "skip")) | length)/\(length) Deployments pass"),
    "",
    (if ($all | map(select(.r != "pass" and .r != "skip")) | length) == 0 then "Nothing failing."
     else "Failing:", ($all | map(select(.r != "pass" and .r != "skip")) | sort_by(.d, .p)[] | "  \(.d) [\(.p)]\n      \(.m)") end)'
echo
echo "Running Deployments (only running ones score):"
kubectl get deployments ${deploy:+"$deploy"}
