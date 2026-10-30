# AKS workshop environment

Builds a CCC-hardened, private AKS cluster for the workshop and deploys the
[TraderX demo](../../examples/traderx/traderx-aks-demo.yaml) on it. The cluster
comes from the Azure Verified Module for AKS: its published
[`examples/finos-ccc`](https://registry.terraform.io/modules/Azure/avm-res-containerservice-managedcluster/azurerm/latest/examples/finos-ccc)
example ([source](https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster/tree/main/examples/finos-ccc)).
`10-run-example.sh` downloads the example from the module's GitHub tag
`v<aks_module_version>` (landing-zone variable, default `0.8.6`) and points its
`module "aks"` at the same version in the Terraform registry
(`Azure/avm-res-containerservice-managedcluster/azurerm`).

The landing zone here builds everything that example expects to already exist
on a fresh Azure subscription, plus a jumpbox inside the network. Everything
runs from the jumpbox because the API server is private: `kubectl`, TraderX and
the CCC tests need it, and it keeps the example's Terraform state in one place.

Run every laptop command from this directory (`workshop/aks`). Scripts in
[`scripts/`](scripts) are numbered in the order you run them; the ones marked
"jumpbox" are copied to `/opt/aks-ccc` on the jumpbox.

| Step | Where | Command |
| --- | --- | --- |
| 1. Preflight | laptop | `./scripts/00-preflight.sh` |
| 2. Landing zone | laptop | `cd landing-zone && terraform init && terraform apply` |
| 3. Sync files (only when the jumpbox already existed) | laptop | `./scripts/05-sync-jumpbox.sh` |
| 4. Build and verify the cluster, get kubectl access, install Kyverno, external-dns and the TraderX Kyverno policies | jumpbox | `/opt/aks-ccc/10-run-example.sh` (reinstall add-ons only: `/opt/aks-ccc/15-install-cluster-addons.sh`) |
| 5. Deploy 4 TraderX instances (`traderx-1..4`), each on a load balancer with a private DNS name | jumpbox | `/opt/aks-ccc/30-deploy-traderx.sh` |
| 6. Set up CCC behavioural tests | jumpbox | `/opt/aks-ccc/40-setup-ccc-tests.sh` |
| 7. Run them, get the dashboard | laptop | `./scripts/55-run-ccc-tests-from-laptop.sh` (or `/opt/aks-ccc/50-run-ccc-tests.sh` on the jumpbox) |
| 8. Tear down | jumpbox, then laptop | `/opt/aks-ccc/95-destroy-ccc-tests.sh`, `/opt/aks-ccc/90-destroy-example.sh`, then `terraform destroy` |

```
vnet-hub 10.10.0.0/16                          vnet-spoke 10.20.0.0/16
  AzureFirewallSubnet           10.10.0.0/26     snet-aks-nodes      10.20.0.0/24  (UDR -> firewall if egress_firewall)
  AzureFirewallManagementSubnet 10.10.0.64/26    snet-aks-apiserver  10.20.1.0/28  (delegated to AKS)
  snet-jumpbox                  10.10.1.0/27     snet-aks-endpoints  10.20.2.0/27  (registry private endpoint)
                                               <-- peered -->
service CIDR 10.100.0.0/16, DNS 10.100.0.10, pod CIDR 172.18.0.0/16 (fixed by the example)
private DNS zone workshop.ccc.internal, linked to both VNets (records written by external-dns)
```

The landing zone creates: resource group, Entra admin group (you as member; it
is the cluster's break-glass admin group, which is how you get `kubectl` access),
hub/spoke VNets and peering, the private DNS zone for workload hostnames
(`app_dns_zone_name`, default `workshop.ccc.internal`) and an Ubuntu jumpbox
(SSH only from your IP) with az, terraform, kubectl, kubelogin, helm, the AVM
example branch cloned, `terraform.tfvars.json` pre-filled and the TraderX manifest.

## Workshop settings (low cost)

[`landing-zone/workshop.auto.tfvars.json`](landing-zone/workshop.auto.tfvars.json)
holds the workshop's settings. Terraform loads it automatically, after your
personal `terraform.tfvars`, so edit it to change them:

| Setting | Workshop value | AVM example default |
| --- | --- | --- |
| `egress_firewall` | `false`: AKS egresses through its own load balancer (`outboundType = loadBalancer`) | Firewall Basic with `userDefinedRouting`, ~$0.40/hour |
| `aks_node_vm_size`, `aks_node_count`, `aks_node_max_count`, `aks_node_zones` | 2 × `Standard_D4s_v5` in zone 1, autoscaler pinned at 2 | 2–5 × `Standard_D4s_v5` in zones 1–3 |
| `aks_node_max_pods` | `120` per node, so four TraderX instances (19 pods each) fit; fixed when the cluster is created | `30` |
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

**Tenant, subscription and region** are inputs; the repository hard-codes no
tenant or subscription:

| Variable | Default | Used for |
| --- | --- | --- |
| `TENANT_ID` | the tenant you are signed in to | signs in to that tenant (device code) and checks the subscription is in it |
| `SUBSCRIPTION_ID` | the one in `terraform.tfvars`, else the current `az` account | `subscription_id` in `terraform.tfvars` |
| `LOCATION` | the one in `terraform.tfvars`, else `centralindia` | `location` in `terraform.tfvars` (short name, see `az account list-locations -o table`) |

Rerunning with a different `SUBSCRIPTION_ID` or `LOCATION` updates
`terraform.tfvars`; the preflight refuses while a landing zone is deployed from
this directory, because its local state belongs to one subscription and region.
The landing zone, both clusters, the jumpbox (`env.sh`) and the CCC tests take
all three from there. The Terraform providers use your `az` sign-in, so apply
the landing zone from the same sign-in. To keep a second tenant's sign-in
separate, export `AZURE_CONFIG_DIR` (for example `~/.azure-tenant2`) in that
terminal before `az login`.

```bash
# A different tenant, subscription and region
export AZURE_CONFIG_DIR=~/.azure-tenant2   # optional: separate az sign-in
TENANT_ID=<tenant-id> SUBSCRIPTION_ID=<subscription-id> LOCATION=westeurope ./scripts/00-preflight.sh
```

Zone and SKU support differ by subscription and region: if the preflight
reports zone 1 is not usable, change `aks_node_zones` (or `aks_node_vm_size`) in
`workshop.auto.tfvars.json`.

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

The script logs you in with a device code, replaces the example's files in
`~/aks-avm/examples/finos-ccc` with those of `v<aks_module_version>` (the
Terraform state there is kept), runs `init`/`validate`, deploys
in two stages (see below), asks before applying the full plan (about 42
resources), then runs `terraform plan -detailed-exitcode` and prints IDEMPOTENT
or DRIFT. AVM telemetry is off (`enable_telemetry = false` in the generated
inputs), so IDEMPOTENT is expected. The generated inputs also set
`workload_namespaces = {}`, so the example creates no AKS managed namespace
(its default `workload-a`, with a workload identity); workshop namespaces are
plain Kubernetes namespaces.

Most of the time is AKS: ~5 minutes to create the cluster with the workshop
settings, then ~15–20 minutes while the module's node-pool update replaces the
nodes one at a time. With the example's own settings (Azure Policy, Defender,
Container Insights) the cluster create alone takes ~25 minutes.

**Add-on check (CCC.K8S.CN08.AR01).** After the cluster is created, the example
reads it back and fails the apply with `CCC.K8S.CN08.AR01: the cluster has
add-ons or managed features enabled that are not in var.approved_addons: ...`
if AKS enabled anything outside the example's allowlist. The cluster is left in
place. That is a finding against the example, not the workshop: report the
name it lists.

**Cluster add-ons (workshop only, not part of the example).** After the
apply, the script links the API server's private DNS zone to the hub VNet and
runs `15-install-cluster-addons.sh`, which installs with Helm:

- **Kyverno**, latest chart, namespace `kyverno`, with no policies yet.
- **external-dns**, latest chart, namespace `external-dns`, provider
  `azure-private-dns`, sources `service`, policy `sync`, limited to
  `workshop.ccc.internal`. It signs in with a workload identity that
  [`example/workshop_external_dns.tf`](example/workshop_external_dns.tf) adds
  to the example's state. That identity has Private DNS Zone Contributor on the
  zone and Reader on the resource group, which is the minimum external-dns
  documents. It publishes Services annotated with
  `external-dns.alpha.kubernetes.io/hostname`.

Pin versions with `KYVERNO_CHART_VERSION` / `EXTERNAL_DNS_CHART_VERSION`. The
images come from public registries, which works because Azure Policy is off.
With `aks_azure_policy_enabled = true`, import them into the private registry
first.

**Pod Security labels (workshop only).** Last, the script labels every
namespace except `kube-system` with `pod-security.kubernetes.io/enforce=baseline`
and `pod-security.kubernetes.io/enforce-version=latest`, and lists the result.
`kube-system` gets `pod-security.kubernetes.io/enforce=privileged` instead,
because AKS runs privileged system pods there (Cilium, kube-proxy, CSI drivers)
that baseline would keep from starting on new nodes; the explicit label records
that decision (CCC.K8S.CN11.AR01 needs a label on every namespace).
Namespaces that already enforce `restricted` keep it. kubectl prints a warning
for any running pod that baseline would reject. Namespaces created later label
themselves: `30-deploy-traderx.sh` sets baseline on `traderx-N`, and the CCC
fixtures (`k8s-fixtures.yaml`, `webhook-probe.yaml`) set restricted or baseline.
Any other namespace you create needs the label too, or CCC.K8S.CN11.AR01 fails.

**Security alerts.** The example creates an action group that emails the
subscription's Owners. Expect alert emails when the cluster, role assignments or
network rules change, including during the CCC tests.

**Route table grant (only with `egress_firewall = true`).** The example gives
the new control-plane identity Network Contributor on the node and API-server
subnets only. AKS also needs rights on a bring-your-own route table, which is a
separate resource. By default the script applies
`module.cluster_identities` first, grants that identity Network Contributor on
the route table, then applies everything. To test the example exactly as written:

```bash
GRANT_ROUTE_TABLE=false /opt/aks-ccc/10-run-example.sh
```

If that fails with an authorization error on `routeTables`, the example needs a fix.

**Verification.** The script stops if the jumpbox can't resolve the private API
server. After the add-ons and labels, it prints the security settings from
`az aks show`, lists nodes and `kube-system` pods, creates and reads a test
secret (KMS) and confirms nodes have no public IPs. kubectl uses Entra through
kubelogin, set up by `15-install-cluster-addons.sh`; you must be in the admin group.

**Kyverno policies.** Last, the script applies
[`kyverno-reports-rbac.yaml`](../../examples/traderx/policies/kyverno-reports-rbac.yaml)
(lets Kyverno's reports controller read `pods/ephemeralcontainers`, without
which some policies never become ready) and the TraderX
[`validating-policies.yaml`](../../examples/traderx/policies/validating-policies.yaml).
It waits up to 5 minutes for every ValidatingPolicy to report ready, prints
`kubectl get vpol -A` and fails with each policy's status message if any isn't
ready. The landing zone delivers both files; after editing them, run
`terraform apply` and `./scripts/05-sync-jumpbox.sh` again.

### Deploy TraderX (jumpbox)

```bash
/opt/aks-ccc/30-deploy-traderx.sh
```

Deploys `traderx_instances` (default 4) independent copies of TraderX, one per
namespace: `traderx-1` … `traderx-4`. Each copy is
`/opt/aks-ccc/traderx.yaml` with only the namespace changed. That works because
the services address each other by short name, so every instance has its own
database, message bus and observability stack. The manifest is this
repository's
[`examples/traderx/traderx-aks-demo.yaml`](../../examples/traderx/traderx-aks-demo.yaml),
delivered by the landing zone (set `traderx_manifest_path` to use another
manifest). After editing it, run `terraform apply` and
`./scripts/05-sync-jumpbox.sh` again.

Each instance's entry point (`edge-proxy`) is exposed as an `edge-proxy-public`
Service of type LoadBalancer:

- **Public IP on port 80**, open only to your IP (`admin_ssh_source_cidr`) and the
  jumpbox's public IP, through `loadBalancerSourceRanges`.
- **DNS name:** external-dns publishes `traderx-N.workshop.ccc.internal` as an A
  record for that IP.

The script waits for every instance, IP and record, then prints a table and
`kubectl top nodes`.

- **From the jumpbox:** `curl -sI http://traderx-1.workshop.ccc.internal/`.
- **From your laptop:** open `http://<lb-ip>/`. The private zone doesn't resolve
  outside the VNets, so to use the names, add `<lb-ip> traderx-N.workshop.ccc.internal`
  lines to `/etc/hosts`.
- **Instance count:** change it for one run with `TRADERX_INSTANCES=2 /opt/aks-ccc/30-deploy-traderx.sh`,
  or permanently with `traderx_instances` in the landing zone, followed by
  `terraform apply` and `05-sync-jumpbox.sh`.
- **Lowering the count** doesn't delete instances. Remove one with
  `kubectl delete namespace traderx-<n>`; external-dns then removes its record.

**Capacity.** Each instance runs 19 pods, so four need 76 pod slots on top of
the AKS system pods, Kyverno and external-dns. With the example's 30 pods per
node, the third instance stays `Pending` (`Too many pods`). The workshop
therefore builds the cluster with `aks_node_max_pods = 120`, which gives 240
slots on two nodes. AKS fixes this value when the node pool is created:
`10-run-example.sh` stops and asks you to rebuild an existing cluster that has
a different value (`90-destroy-example.sh`, then `10-run-example.sh`).

TraderX also sets no CPU or memory requests. The scheduler therefore places
every instance without checking capacity, and the cluster autoscaler never adds
a node. Four instances share the two `Standard_D4s_v5` nodes (8 vCPU, 32 GiB).
If `kubectl top nodes` shows memory near the limit, or pods restart with
`OOMKilled`, run fewer instances, or raise `aks_node_count` and
`aks_node_max_count` in `workshop.auto.tfvars.json`. The 16-vCPU DSv5 quota
allows up to 4 nodes.

This needs `aks_azure_policy_enabled = false` (the workshop value). With it
enabled the example assigns deny-mode Azure Policy: images only from its private registry pinned by
`@sha256` digest, the restricted pod security standard and CPU/memory limits of
at most 1000m/2Gi per container, which the TraderX manifest does not meet.

## 5. CCC behavioural tests and compliance dashboard

To run the same tests against a plain AKS cluster built with the published AVM
module (no PR #333 controls) for comparison, see [`../aks-vanilla`](../aks-vanilla).
It reuses this landing zone, jumpbox and these scripts (`CCC_TARGET=vanilla`).

These tests check the cluster against the FINOS Common Cloud Controls
(CCC.K8S, plus the CCC.Core requirements that apply to Kubernetes). They use
[common-cloud-controls](https://github.com/finos/common-cloud-controls), branch
`main` (the Kubernetes tests were merged there from `managed-k8s-behavioural` in
[#1288](https://github.com/finos/common-cloud-controls/pull/1288); override with
`CCC_REPO_BRANCH`): Privateer (`pvtr`) runs `ccc-behavioural-plugin`,
which runs the Gherkin scenarios in `modules/features/kubernetes`.

```
laptop                                   jumpbox (hub VNet)                         AKS (private API)
55-run-ccc-tests-from-laptop.sh ──ssh──> 50-run-ccc-tests.sh
  reachability observer <── reverse ───   run-compliance-tests.sh -> pvtr -> plugin ──> ARM + private API
  (untrusted vantage for CN01)  tunnel                                              fixtures in ccc-test, ...
  ccc-results/<time>/dashboard.html <──── ~/ccc-tests/results/<time>/
```

The run happens on the jumpbox because the API server is private and the
example disables AKS Run Command, which the plugin's other access mode
(`command-invoke`) needs. The config uses `azure-aks-kube-transport: direct`.

### Set up (jumpbox, once, ~15–20 min)

After `10-run-example.sh` (it links the API DNS zone to the hub VNet):

```bash
/opt/aks-ccc/40-setup-ccc-tests.sh
```

It installs Go, Node.js 22, `pvtr` and `ko`, clones common-cloud-controls,
generates its DEV catalogs, and creates the fixtures the scenarios expect
(ported from the upstream CI fixtures):

| Fixture | Where | Used by |
| --- | --- | --- |
| Entra service principal with no role assignments (`test-user-no-access`) | Entra ID | CCC.Core.CN05.AR06, CCC.K8S.CN15.AR02 |
| Managed identity federated to `ccc-test/ccc-wi-sa`, Blob Data Reader on a small storage account holding `probe/probe.txt` | resource group | CCC.K8S.CN03.AR01 |
| Namespaces `ccc-test` (Pod Security restricted, default-deny network policies, LimitRange, quota) and `ccc-network-control`, listeners, secrets, storage classes, ValidatingAdmissionPolicies scoped to `ccc-test` | cluster ([`ccc-tests/k8s-fixtures.yaml`](ccc-tests/k8s-fixtures.yaml)) | CN03–CN07, CN10, CN13 |
| Admission webhook probe with `failurePolicy: Fail`, only for labelled Pods in `ccc-admission-webhook-test`; image built with `ko` and pushed to the workshop registry | cluster ([`ccc-tests/webhook-probe.yaml`](ccc-tests/webhook-probe.yaml)) | CCC.K8S.CN11.AR03 |

The service principal's secret is kept only in `~/ccc-tests/ccc-test-env.sh`
(mode 0600) on the jumpbox. The extra cost is pennies (one storage account, a
1 GiB test disk created and deleted during the run).

### Run (laptop, ~20–40 min; the first run adds 15–30 min of Go compilation)

The first run compiles the CCC Go modules on the jumpbox. On the 4 GB
`Standard_B2als_v2` it swaps and prints nothing for long stretches; that is
not a hang (check with `top` on the jumpbox). Later runs reuse the build cache.

```bash
./scripts/55-run-ccc-tests-from-laptop.sh
```

It builds the CCC reachability observer for your laptop on the jumpbox, starts
it on `127.0.0.1:18080` and runs `/opt/aks-ccc/50-run-ccc-tests.sh` over SSH
with a reverse tunnel, so CCC.K8S.CN01 ("API not reachable from an untrusted
network") is probed from your laptop rather than from the jumpbox, which is
inside the approved network. Results land in `ccc-results/<UTC time>/`
(gitignored) and the dashboard opens.

You can also run `/opt/aks-ccc/50-run-ccc-tests.sh` directly on the jumpbox;
CN01 is then probed from the jumpbox and the dashboard flags it. Options:
`CCC_TAGS='@CCC.K8S.CN06'` (run a subset), `CCC_DEBUG=1` (run the plugin
in-process without `pvtr`, as upstream CI does), `CCC_TIMEOUT=90m`.

Each run directory contains:

- `dashboard.html`: one page with compliance percentage, pass/fail per
  catalog, every control and assessment requirement with its scenarios and the
  first failing step, workshop notes for failures explained by the low-cost
  settings, and the CCC.K8S requirements that have no behavioural test;
- `html/` (the runner's detailed report and `summary.html`), `ocsf/`
  (OCSF findings), Privateer's evaluation YAML, `privateer-config.yml` (no
  secrets) and `run.log`.

### What to expect with the workshop settings

These come from the low-cost settings, not from the AVM example:

- **CCC.Core.CN04, CCC.K8S.CN14 (audit logging) fail**:
  `aks_monitoring_enabled = false` sends no audit logs to Log Analytics. To
  test them, set it to `true`, apply the landing zone and the example, wait
  ~15 minutes and rerun (Log Analytics ingestion is billed per GB). With it
  on, `example/workshop_override.tf` also enables public query access on the
  workspace: the example keeps queries private (AVM default), so the tests'
  log queries from the jumpbox fail with `NspValidationFailedError` (403).
  Queries still need Entra ID sign-in and RBAC on the workspace.
- **CCC.K8S.CN11.AR01 fails** while any namespace has no
  `pod-security.kubernetes.io/enforce` label. `10-run-example.sh` labels every
  namespace (`kube-system` as `privileged`), so namespaces created after it
  (`traderx-N`) fail it until you rerun the script. The Azure Policy add-on is off.
- The test namespace has its own guardrails (above), so admission scenarios
  check that guardrail pattern, not cluster-wide policy.

The tests are from a work-in-progress upstream branch, so some failures can be
in the scenarios themselves; the dashboard shows the failing step and error so
you can tell. `ccc-tests/privateer-config.yml.tmpl` works around two harness
issues: the AKS audit query expects columns the resource-specific `AKSAudit`
table does not have (CN04.AR02/AR03, `azure-k8s-audit-table`), and AKS add-on
ClusterRoles are not treated as system roles (CN02.AR02, `system-role-prefixes`).
Known harness issues without a workaround:

- **CCC.K8S.CN03.AR02**: the guardrail denies the static-credential pod, but
  the harness treats any denial whose message contains "forbidden" (every
  ValidatingAdmissionPolicy denial) as a missing permission ("unassessed").
- **CCC.K8S.CN13.AR01/AR02**: the scenarios expect an error, but the harness
  returns `Denied: true` without an error for denials whose message lacks
  "forbidden" (the LimitRange rejects the quota pod as Invalid), and the
  `ccc-test` LimitRange defaults bounds for pods without them, which the
  harness's own network-probe Jobs rely on.

CN04/CN14 also add the tag `ccc_compliance_test` to the cluster;
the example's next `terraform plan` removes it (expected drift).

## 6. Tear down (stop the costs)

```bash
/opt/aks-ccc/95-destroy-ccc-tests.sh      # on the jumpbox, if you set up the CCC tests
/opt/aks-ccc/90-destroy-example.sh        # on the jumpbox
cd landing-zone && terraform destroy      # on the laptop
```

The vault and keys stay soft-deleted for 90 days (purge protection). They cost
nothing, and their names include a random suffix, so redeploying does not clash.

## Cost (rough, check the pricing calculator)

With the workshop settings: 2 × D4s_v5 nodes (~$0.40/hour) and their OS disks,
B2als_v2 jumpbox (~$0.03/hour), the cluster load balancer and public IPs (one per TraderX instance,
a few cents/hour each), the private DNS zone (~$0.50/month), a Basic registry (~$0.01/hour) and Key Vault keys (pennies) ≈
$0.45–0.50/hour. The nodes are most of it: stop the cluster when idle with
`az aks stop -g rg-ccc-aks-test -n <cluster>` (and `az aks start` later), and
deallocate the jumpbox with `az vm deallocate`. With the AVM example's
own settings (Firewall Basic, AKS Standard tier, Premium registry, Log Analytics
ingestion, Defender) expect roughly $1/hour or more.
