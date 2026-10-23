#!/usr/bin/env bash
# Run ON THE JUMPBOX after 20-verify-cluster.sh: /opt/aks-ccc/30-deploy-traderx.sh
# Deploys TRADERX_INSTANCES independent copies of /opt/aks-ccc/traderx.yaml
# (examples/traderx/traderx-aks-demo.yaml from this repository, delivered by the
# landing zone) into namespaces traderx-1 .. traderx-N, and exposes each one's
# edge-proxy on a public load balancer open only to LB_ALLOWED_CIDRS (you and the
# jumpbox). external-dns publishes traderx-N.<APP_DNS_ZONE_NAME> in the private
# DNS zone. Rerunning is safe; set TRADERX_INSTANCES=<n> to override env.sh.
set -euo pipefail
REQUESTED_INSTANCES="${TRADERX_INSTANCES:-}" # a value on the command line wins over env.sh
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
MANIFEST="${MANIFEST:-/opt/aks-ccc/traderx.yaml}"
TRADERX_INSTANCES="${REQUESTED_INSTANCES:-${TRADERX_INSTANCES:-4}}"
NAMESPACES=()
for i in $(seq "$TRADERX_INSTANCES"); do NAMESPACES+=("traderx-$i"); done

[[ -f "$MANIFEST" ]] || { echo "$MANIFEST not found. From your laptop run workshop/aks/scripts/05-sync-jumpbox.sh, then rerun $0"; exit 1; }
[[ -n "${APP_DNS_ZONE_NAME:-}" && -n "${LB_ALLOWED_CIDRS:-}" ]] || {
  echo "env.sh has no APP_DNS_ZONE_NAME/LB_ALLOWED_CIDRS: apply the landing zone and run 05-sync-jumpbox.sh from your laptop."
  exit 1
}

az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"
CLUSTER_NAME="$(terraform -chdir="$EXAMPLE_DIR" output -raw cluster_name)"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

# The manifest names its namespace only in the Namespace object and in each
# object's metadata.namespace; services address each other by short name, so a
# copy with the namespace replaced is a fully independent instance.
render() {
  sed -e "s/^  name: traderx$/  name: $1/" -e "s/^  namespace: traderx$/  namespace: $1/" "$MANIFEST"
}

for ns in "${NAMESPACES[@]}"; do
  host="$ns.$APP_DNS_ZONE_NAME"
  echo "==> $ns: applying TraderX and exposing it as $host"
  rendered="$(render "$ns")"
  if grep -qE '^  (name|namespace): traderx$' <<<"$rendered"; then
    echo "The manifest still references namespace traderx after rendering"; exit 1
  fi
  kubectl apply -f - >/dev/null <<<"$rendered"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: edge-proxy-public
  namespace: $ns
  labels:
    app: edge-proxy
  annotations:
    external-dns.alpha.kubernetes.io/hostname: $host
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
done

failed=()
for ns in "${NAMESPACES[@]}"; do
  echo "==> $ns: waiting for deployments"
  if ! kubectl -n "$ns" wait deployment --all --for=condition=Available --timeout=15m; then
    kubectl -n "$ns" get pods -o wide
    failed+=("$ns")
  fi
done

echo "==> Waiting up to 5 minutes for load balancer IPs and DNS records"
declare -A LB_IP DNS_IP
for attempt in $(seq 60); do
  lb_ready=0 dns_ready=0
  for ns in "${NAMESPACES[@]}"; do
    LB_IP[$ns]="$(kubectl -n "$ns" get svc edge-proxy-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    DNS_IP[$ns]="$(dig +short "$ns.$APP_DNS_ZONE_NAME" | tail -1)"
    [[ -n "${LB_IP[$ns]}" ]] && lb_ready=$((lb_ready + 1))
    [[ -n "${LB_IP[$ns]}" && "${DNS_IP[$ns]}" == "${LB_IP[$ns]}" ]] && dns_ready=$((dns_ready + 1))
  done
  ((dns_ready == ${#NAMESPACES[@]})) && break
  ((attempt % 6 == 1)) && echo "    load balancer IPs ${lb_ready}/${#NAMESPACES[@]}, DNS records ${dns_ready}/${#NAMESPACES[@]}"
  sleep 5
done
if ((dns_ready < ${#NAMESPACES[@]})); then
  echo "==> DNS records missing; external-dns status"
  kubectl -n external-dns get pods -o wide || true
  kubectl -n external-dns logs deploy/external-dns --tail=30 || true
fi

echo
printf '%-12s %-16s %-36s %s\n' NAMESPACE LB_IP HOSTNAME DNS
for ns in "${NAMESPACES[@]}"; do
  status=ok
  [[ -n "${LB_IP[$ns]}" ]] || status="no LB IP (kubectl -n $ns describe svc edge-proxy-public)"
  [[ -z "${LB_IP[$ns]}" || "${DNS_IP[$ns]}" == "${LB_IP[$ns]}" ]] || status="resolves to '${DNS_IP[$ns]}' (kubectl -n external-dns logs deploy/external-dns)"
  printf '%-12s %-16s %-36s %s\n' "$ns" "${LB_IP[$ns]:--}" "$ns.$APP_DNS_ZONE_NAME" "$status"
done

echo
echo "==> Node usage (TraderX sets no resource requests, so the scheduler does not reserve capacity)"
kubectl top nodes || true

if kubectl get namespace traderx >/dev/null 2>&1; then
  echo
  echo "Note: namespace 'traderx' from an earlier single-instance run still exists. Remove it with: kubectl delete namespace traderx"
fi

cat <<EOF

From the jumpbox:  curl -sI http://traderx-1.$APP_DNS_ZONE_NAME/
From your laptop:  http://<LB_IP>/ (the private zone only resolves inside the VNets;
                   add "<LB_IP> <HOSTNAME>" lines to /etc/hosts to use the names).
Grafana per instance: http://<LB_IP>/grafana/
Remove an instance: kubectl delete namespace traderx-<n>
EOF

if ((${#failed[@]})); then
  echo "Some deployments are not ready in: ${failed[*]}. Check: kubectl -n <ns> describe pod <name> / kubectl -n <ns> logs <name>"
  exit 1
fi
