# Vanilla AKS baseline for the CCC behavioural tests

Builds a plain AKS cluster with the Azure Verified Module as published today, with
none of the CCC controls from
[PR #333](https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster/pull/333),
and runs the same FINOS CCC behavioural tests against it. Compare its dashboard
with the hardened workshop cluster's ([`../aks`](../aks)) to see what the
`finos-ccc` example adds.

It reuses the hardened workshop's landing zone, jumpbox and CCC test scripts.
Build the landing zone first ([`../aks/README.md`](../aks/README.md), steps 1–2).
Run one cluster at a time: two 2 × `Standard_D4s_v5` clusters exceed the 16-vCPU
DSv5 quota.

## What it deploys

[`terraform/main.tf`](terraform/main.tf) is the AVM module's
[`default` example at v0.8.5](https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster/tree/v0.8.5/examples/default),
with these changes (each marked `Workshop:` in the file):

| Change | Why |
| --- | --- |
| `source = "Azure/avm-res-containerservice-managedcluster/azurerm"`, `version = "0.8.5"` | The published module, not the repository checkout. |
| Region from the landing zone (`centralindia`) instead of a random `northeurope` pick | Same region as the workshop. |
| `admin_group_object_ids` = the landing zone's AKS admin group (example: empty) | With Entra ID and Azure RBAC on, an empty list gives nobody `kubectl` access. |
| 2 × `Standard_D4s_v5` nodes (example: 1 × `Standard_B2s_v2`) | Same nodes as the hardened cluster. |
| `enable_telemetry = false` | Clean idempotency check. |

So the cluster has what the example sets: Entra ID with Azure RBAC, Container
Insights and diagnostic settings to its own Log Analytics workspace, Standard
tier, no automatic upgrades. Everything else is the AKS default, including a
**public API server**, local accounts enabled, no OIDC issuer or workload
identity, no network policy engine, no Azure Policy, no Defender, no KMS and no
customer-managed disk encryption.

[`terraform/ccc_test_scaffolding.tf`](terraform/ccc_test_scaffolding.tf) adds the
one thing the tests need that the cluster doesn't have: a Basic container
registry with AcrPull for the kubelet identity, for the admission-webhook probe
image. The cluster itself is unchanged.

## Steps

| Step | Where | Command |
| --- | --- | --- |
| 0a. Landing zone and jumpbox, if they don't exist (~15 min, then ~5 min bootstrap) | laptop | `cd workshop/aks/landing-zone && terraform init && terraform apply` |
| 0b. Remove the hardened cluster, if it exists | jumpbox | `/opt/aks-ccc/95-destroy-ccc-tests.sh`, `/opt/aks-ccc/90-destroy-example.sh` |
| 1. Copy the Terraform and scripts to the jumpbox | laptop | `workshop/aks-vanilla/scripts/05-sync-jumpbox.sh` |
| 2. Build the cluster (~10 min) | jumpbox | `/opt/aks-ccc/vanilla/10-build-cluster.sh` |
| 3. Set up the CCC tests | jumpbox | `/opt/aks-ccc/vanilla/40-setup-ccc-tests.sh` |
| 4. Run them, get the dashboard | laptop | `workshop/aks-vanilla/scripts/55-run-ccc-tests-from-laptop.sh` (or `/opt/aks-ccc/vanilla/50-run-ccc-tests.sh` on the jumpbox) |
| 5. Tear down | jumpbox | `/opt/aks-ccc/vanilla/95-destroy-ccc-tests.sh`, then `/opt/aks-ccc/vanilla/90-destroy-cluster.sh` |

- **Step 1** writes `terraform.tfvars.json` (subscription, region and admin group,
  read from the landing zone) to `~/aks-vanilla` on the jumpbox. Terraform state
  stays there, as it does for the hardened cluster. If the jumpbox's CCC scripts
  are older than this setup, the script asks you to refresh them first: from
  `workshop/aks`, run `(cd landing-zone && terraform apply) && ./scripts/05-sync-jumpbox.sh`.
- **Step 2** runs `init`, `plan` (13 resources), asks before applying, checks
  idempotency, fetches Entra credentials and prints the cluster's settings.
- **Steps 3–5** are the hardened workshop's scripts with `CCC_TARGET=vanilla`:
  same toolchain and CCC repository, same fixtures, same Privateer config and
  dashboard. They use their own work directory (`~/ccc-tests-vanilla`), test
  identities and results, so the two clusters' runs don't mix. Results are
  copied to `workshop/aks-vanilla/ccc-results/` (gitignored).

## What to expect

These are the findings this baseline exists to show; they are not setup problems:

- **CCC.K8S.CN01**: the API server is public, so the laptop's untrusted-network probe
  reaches it.
- **CCC.K8S.CN03.AR01**: there is no OIDC issuer, so the setup skips the workload
  identity probe and the scenario fails.
- **CCC.K8S.CN06**: network policies aren't enforced (no policy engine).
- **CCC.K8S.CN11 / CN05**: there is no admission policy (no Azure Policy add-on).
- **CCC.K8S.CN16**: local accounts are enabled.

The dashboard omits the hardened workshop's low-cost notes
(`--no-workshop-notes`), because they don't apply here.

## Cost

About the same as the hardened workshop's cluster: 2 × D4s_v5 (~$0.40/hour), the
Standard tier (~$0.10/hour), a Basic registry and Log Analytics ingestion from
Container Insights. Tear it down when you're done.
