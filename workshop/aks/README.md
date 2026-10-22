# AKS workshop environment

Builds a CCC-hardened, private AKS cluster for the workshop and deploys the
[TraderX demo](../../examples/traderx/traderx-aks-demo.yaml) on it. The cluster
comes from the Azure Verified Module for AKS: its
[`examples/finos-ccc`](https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster/pull/333)
example, currently taken from the PR #333 branch
(`example_repo_url` / `example_repo_branch` in the landing zone).

The landing zone here builds everything that example expects to already exist
on a fresh Azure subscription, plus a jumpbox inside the network. The example
runs from the jumpbox because its Key Vault and API server are private.

Run every laptop command from this directory (`workshop/aks`). Scripts in
[`scripts/`](scripts) are numbered in the order you run them; the ones marked
"jumpbox" are copied to `/opt/aks-ccc` on the jumpbox.

| Step | Where | Command |
| --- | --- | --- |
| 1. Preflight | laptop | `./scripts/00-preflight.sh` |
| 2. Landing zone | laptop | `cd landing-zone && terraform init && terraform apply` |
| 3. Sync files (only when the jumpbox already existed) | laptop | `./scripts/05-sync-jumpbox.sh` |
| 4. Build the cluster | jumpbox | `/opt/aks-ccc/10-run-example.sh` |
| 5. Verify and get kubectl access | jumpbox | `/opt/aks-ccc/20-verify-cluster.sh` |
| 6. Deploy TraderX | jumpbox | `/opt/aks-ccc/30-deploy-traderx.sh` |
| 7. Tear down | jumpbox, then laptop | `/opt/aks-ccc/90-destroy-example.sh`, then `terraform destroy` |

```
vnet-hub 10.10.0.0/16                          vnet-spoke 10.20.0.0/16
  AzureFirewallSubnet           10.10.0.0/26     snet-aks-nodes      10.20.0.0/24  (UDR -> firewall if egress_firewall)
  AzureFirewallManagementSubnet 10.10.0.64/26    snet-aks-apiserver  10.20.1.0/28  (delegated to AKS)
  snet-jumpbox                  10.10.1.0/27     snet-aks-endpoints  10.20.2.0/27  (registry private endpoint)
  snet-private-endpoints        10.10.2.0/27   <-- peered -->
service CIDR 10.100.0.0/16, DNS 10.100.0.10, pod CIDR 172.18.0.0/16 (fixed by the example)
```

The landing zone creates: resource group, Entra admin group (you as member),
**Key Vault Crypto Officer** for you on the resource group, hub/spoke VNets and
peering and an Ubuntu jumpbox (SSH only from your IP) with az, terraform, kubectl,
kubelogin, the AVM example branch cloned, `terraform.tfvars.json` pre-filled and
the TraderX manifest.

## Workshop settings (low cost)

[`landing-zone/workshop.auto.tfvars.json`](landing-zone/workshop.auto.tfvars.json)
holds the workshop's settings. Terraform loads it automatically, after your
personal `terraform.tfvars`, so edit it to change them:

| Setting | Workshop value | AVM example default |
| --- | --- | --- |
| `egress_firewall` | `false`: AKS egresses through its own load balancer (`outboundType = loadBalancer`) | Firewall Basic with `userDefinedRouting`, ~$0.40/hour |
| `aks_node_vm_size`, `aks_node_count`, `aks_node_max_count`, `aks_node_zones` | 2 × `Standard_D4s_v5` in zone 1, autoscaler pinned at 2 | 2–5 × `Standard_D4s_v5` in zones 1–3 |
| `aks_sku_tier` | `Free` | `Standard` (uptime SLA), ~$0.10/hour |
| `aks_azure_policy_enabled` | `false`, so TraderX's public images run | Azure Policy add-on with deny-mode assignments |
| `aks_defender_enabled` | `false` | Defender for Containers, billed per vCPU |
| `aks_monitoring_enabled` | `false`: no Log Analytics ingestion | Container Insights and AKS diagnostic logs |
| `aks_container_registry_sku` | `Basic` (public) | `Premium`, private endpoint, zone redundant |
| `jumpbox_vm_size` | `Standard_B2als_v2` | n/a (landing zone only) |

The AVM example is not changed. The landing zone passes the `aks_*` values into
the example's generated `terraform.tfvars.json` as `workshop_*` variables, and
`10-run-example.sh` copies [`example/workshop_variables.tf`](example/workshop_variables.tf)
and [`example/workshop_override.tf`](example/workshop_override.tf) into the
jumpbox's clone to apply them. Without those values the example's own settings
apply.

## 0. Account prerequisites (portal, once)

1. The default sizing is 2 × `Standard_D4s_v5` AKS nodes in zone 1 and a
   `Standard_B2als_v2` jumpbox: 10 vCPUs. **Free Trial** caps regional vCPUs
   at 4 and the cap cannot be raised, so upgrade to Pay-As-You-Go first:
   Subscriptions > your subscription > **Upgrade subscription** (remaining
   credit is kept until 30 days after sign-up). Preflight then requests the
   quota.
2. Create a budget alert: Cost Management > Budgets.

Tools on your laptop (or use Azure Cloud Shell, which has all of them):
Azure CLI, Terraform >= 1.9, jq, curl, ssh.

## 1. Preflight (laptop / Cloud Shell)

```bash
LOCATION=centralindia ./scripts/00-preflight.sh
```

Registers providers, checks that the node size is usable in the chosen zones
for your subscription (some subscriptions are restricted to zone 1) and that the
jumpbox size is usable in the region, checks `cores` and per-family vCPU quota
(and requests more if needed and possible), prints GA Kubernetes versions,
creates `~/.ssh/id_rsa` if missing and writes `landing-zone/terraform.tfvars`
with your subscription, region, public IP and SSH key.

The sizes and zones it checks come from `workshop.auto.tfvars.json`. If it
reports that more zones are usable for your subscription, you can set
`aks_node_zones` to `["1", "2", "3"]` there. The quota requested covers the
autoscaler maximum and the jumpbox; an AKS upgrade adds a surge node (4 more
vCPUs).

In Cloud Shell, the detected IP and SSH key belong to Cloud Shell, so SSH to the
jumpbox from Cloud Shell too. Cloud Shell's IP can change between sessions; if SSH
stops working, update `admin_ssh_source_cidr` and run `terraform apply` again.

## 2. Landing zone (laptop / Cloud Shell, ~15 min)

```bash
cd landing-zone
terraform init
terraform apply
terraform output jumpbox_ssh
```

After changing the landing zone or these scripts later, run `terraform apply`
again and then `./scripts/05-sync-jumpbox.sh` to copy the new `env.sh`,
example inputs, scripts and TraderX manifest to the existing jumpbox. Terraform
does not replace the jumpbox for these changes (that would lose the example's
state on it).

## 3. Build the cluster (jumpbox, ~20–30 min)

```bash
ssh azureuser@<jumpbox-ip>
cloud-init status --wait          # bootstrap takes ~5 min after the VM is up
/opt/aks-ccc/10-run-example.sh
```

The script logs you in with a device code, runs `init`/`validate`, deploys
in two stages (see below), asks before applying the full plan, then runs
`terraform plan -detailed-exitcode` and prints IDEMPOTENT or DRIFT.

**Route table grant (only with `egress_firewall = true`).** The example gives
the new control-plane identity Network Contributor on the node and API-server
subnets only. AKS also needs rights on a bring-your-own route table, which is a
separate resource. By default the script applies
`module.cluster_identities` first, grants that identity Network Contributor on
the route table, then applies everything. To test the PR exactly as written:

```bash
GRANT_ROUTE_TABLE=false /opt/aks-ccc/10-run-example.sh
```

If that fails with an authorization error on `routeTables`, the PR needs a fix.

## 4. Verify (jumpbox)

```bash
/opt/aks-ccc/20-verify-cluster.sh
```

Links the cluster's private API DNS zone to the hub VNet, prints the security
settings from `az aks show`, logs in with Entra via kubelogin, lists nodes and
pods, creates and reads a test secret (KMS) and confirms nodes have no public IPs.

### Deploy TraderX (jumpbox)

```bash
/opt/aks-ccc/30-deploy-traderx.sh
```

Applies `/opt/aks-ccc/traderx.yaml` and waits for every deployment in the
`traderx` namespace. That file is this repository's
[`examples/traderx/traderx-aks-demo.yaml`](../../examples/traderx/traderx-aks-demo.yaml),
delivered by the landing zone (set `traderx_manifest_path` to use another
manifest). After editing it, run `terraform apply` and
`./scripts/05-sync-jumpbox.sh` again. The script prints the port-forward
commands to open the UI from your laptop.

This needs `aks_azure_policy_enabled = false` (the workshop value). With it
enabled the example assigns deny-mode Azure Policy: images only from its private registry pinned by
`@sha256` digest, the restricted pod security standard and CPU/memory limits of
at most 1000m/2Gi per container, which the TraderX manifest does not meet.

## 5. Tear down (stop the costs)

```bash
/opt/aks-ccc/90-destroy-example.sh        # on the jumpbox
cd landing-zone && terraform destroy      # on the laptop
```

The vault and keys stay soft-deleted for 90 days (purge protection). They cost
nothing, and their names include a random suffix, so redeploying does not clash.

## Cost (rough, check the pricing calculator)

With the workshop settings: 2 × D4s_v5 nodes (~$0.40/hour) and their OS disks,
B2als_v2 jumpbox (~$0.03/hour), the cluster load balancer and public IP (a few
cents/hour), a Basic registry (~$0.01/hour) and Key Vault keys (pennies) ≈
$0.45–0.50/hour. The nodes are most of it: stop the cluster when idle with
`az aks stop -g rg-ccc-aks-test -n <cluster>` (and `az aks start` later), and
deallocate the jumpbox with `az vm deallocate`. With the AVM example's
own settings (Firewall Basic, AKS Standard tier, Premium registry, Log Analytics
ingestion, Defender) expect roughly $1/hour or more.
