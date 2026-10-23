#!/usr/bin/env bash
# Run ON THE JUMPBOX. 10-run-example.sh runs it after the cluster build; rerun it any
# time (it upgrades in place): /opt/aks-ccc/15-install-cluster-addons.sh
#
# Installs, with Helm:
#   - Kyverno (latest chart, no policies yet), namespace kyverno
#   - external-dns (latest chart), namespace external-dns. It manages A and TXT records
#     in the landing zone's private DNS zone ($APP_DNS_ZONE_NAME) for Services annotated
#     with external-dns.alpha.kubernetes.io/hostname, authenticating with the workload
#     identity from workshop_external_dns.tf.
# Pin chart versions with KYVERNO_CHART_VERSION / EXTERNAL_DNS_CHART_VERSION.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-}"
EXTERNAL_DNS_CHART_VERSION="${EXTERNAL_DNS_CHART_VERSION:-}"
# Fixed so records written by an earlier workshop cluster are adopted, not orphaned.
EXTERNAL_DNS_OWNER_ID=aks-ccc-workshop

az account show >/dev/null 2>&1 || az login --use-device-code --tenant "$TENANT_ID" >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"

command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

tf_out() { terraform -chdir="$EXAMPLE_DIR" output -raw "$1" 2>/dev/null || true; }
CLUSTER_NAME="$(tf_out cluster_name)"
[[ -n "$CLUSTER_NAME" ]] || { echo "No cluster in $EXAMPLE_DIR; run /opt/aks-ccc/10-run-example.sh first"; exit 1; }
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update >/dev/null
helm repo update kyverno external-dns >/dev/null

echo "==> Kyverno ${KYVERNO_CHART_VERSION:-latest}"
helm upgrade --install kyverno kyverno/kyverno --namespace kyverno --create-namespace \
  ${KYVERNO_CHART_VERSION:+--version "$KYVERNO_CHART_VERSION"} --wait --timeout 10m

CLIENT_ID="$(tf_out workshop_external_dns_client_id)"
if [[ -z "$CLIENT_ID" || -z "${APP_DNS_ZONE_NAME:-}" ]]; then
  echo "Skipping external-dns: no workshop_external_dns_client_id output or APP_DNS_ZONE_NAME."
  echo "Apply the landing zone, run 05-sync-jumpbox.sh and rerun 10-run-example.sh."
  exit 0
fi

echo "==> external-dns ${EXTERNAL_DNS_CHART_VERSION:-latest} for $APP_DNS_ZONE_NAME"
AZURE_JSON="$(jq -cn --arg t "$TENANT_ID" --arg s "$SUBSCRIPTION_ID" --arg g "$RESOURCE_GROUP" \
  '{tenantId: $t, subscriptionId: $s, resourceGroup: $g, useWorkloadIdentityExtension: true}')"
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-dns create secret generic external-dns-azure --from-literal=azure.json="$AZURE_JSON" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install external-dns external-dns/external-dns --namespace external-dns \
  ${EXTERNAL_DNS_CHART_VERSION:+--version "$EXTERNAL_DNS_CHART_VERSION"} --wait --timeout 10m -f - <<EOF
fullnameOverride: external-dns
serviceAccount:
  name: external-dns
  annotations:
    azure.workload.identity/client-id: "$CLIENT_ID"
podLabels:
  azure.workload.identity/use: "true"
podAnnotations:
  # Restarts the pod when the identity or Azure config changes.
  checksum/azure-config: "$(sha256sum <<<"$AZURE_JSON$CLIENT_ID" | cut -c1-16)"
provider:
  name: azure-private-dns
sources: [service]
domainFilters: ["$APP_DNS_ZONE_NAME"]
policy: sync
registry: txt
txtOwnerId: $EXTERNAL_DNS_OWNER_ID
extraArgs:
  - --azure-resource-group=$RESOURCE_GROUP
  - --azure-subscription-id=$SUBSCRIPTION_ID
extraVolumes:
  - name: azure-config-file
    secret:
      secretName: external-dns-azure
extraVolumeMounts:
  - name: azure-config-file
    mountPath: /etc/kubernetes
    readOnly: true
EOF

helm list -A --filter '^(kyverno|external-dns)$'
kubectl -n kyverno get pods
kubectl -n external-dns get pods
echo "external-dns logs: kubectl -n external-dns logs deploy/external-dns"
