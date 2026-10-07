# AKS blueprint

A Terraform module that uses the AzAPI provider to create a private, hardened Azure Kubernetes Service (AKS) cluster. Prerequisite infrastructure is left to the caller.

## What this module creates

- One `Microsoft.ContainerService/managedClusters` resource
- Its default system pool and optional additional agent pools
- An optional weekly node OS maintenance configuration

The resource group, networking, private DNS zone, managed identities, disk encryption set, Key Vault, KMS key, and their role assignments must already exist.

## Enforced baseline

- Private API server with no public private-cluster FQDN
- User-assigned control-plane and kubelet identities
- Kubernetes RBAC and managed Microsoft Entra integration
- OIDC issuer and workload identity
- Customer-managed node disk encryption and private Key Vault KMS
- Ubuntu Linux node pools without node public IPs
- Node SSH through Microsoft Entra ID on every pool, with no SSH keys
- Standard load balancer with user-defined routing
- Azure CNI Overlay with the Cilium data plane and network policy, using pod CIDR `172.18.0.0/16`
- Azure Policy add-on disabled

The module does not yet set controls such as disabling local accounts or Run Command, Microsoft Defender, Image Cleaner, FIPS, host encryption, Trusted Launch, or node resource-group lockdown.

## Usage

```hcl
module "aks" {
  source = "github.com/finos/ccc-managed-k8s//aks"

  name               = "example-aks"
  location           = "eastus2"
  resource_group_id  = azurerm_resource_group.aks.id
  kubernetes_version = "1.32"

  private_dns_zone_id       = azurerm_private_dns_zone.aks.id
  control_plane_identity_id = azurerm_user_assigned_identity.aks.id
  kubelet_identity_id       = azurerm_user_assigned_identity.kubelet.id
  disk_encryption_set_id    = azurerm_disk_encryption_set.aks.id
  key_vault_key_id          = azurerm_key_vault_key.kms.id
  key_vault_resource_id     = azurerm_key_vault.aks.id

  cluster_admin_group_object_ids = [var.aks_admin_group_object_id]
  subnet_id                      = azurerm_subnet.nodes.id

  node_pools = [
    {
      name              = "system"
      vm_size           = "Standard_D4s_v5"
      node_count        = 3
      max_pods_per_node = 30
      system_nodepool   = true
    },
    {
      name                = "apps"
      vm_size             = "Standard_D8s_v5"
      max_pods_per_node   = 50
      enable_auto_scaling = true
      min_count           = 2
      max_count           = 10
    },
  ]
}
```

Before the cluster is created, the control-plane identity needs the permissions AKS requires on the private DNS zone, network, kubelet identity, disk encryption set, and KMS resources.

Microsoft Entra ID node SSH is an AKS preview feature. Register it once per subscription before creating a cluster:

```shell
az feature register --namespace Microsoft.ContainerService --name EntraIdSSHPreview
az provider register --namespace Microsoft.ContainerService
```

Users who SSH to nodes need the Virtual Machine User Login or Virtual Machine Administrator Login role. For other troubleshooting, use `kubectl debug`.

[`example.tfvars.json`](example.tfvars.json) is a complete sample input. It enables autoscaling, additional and Spot pools, node OS maintenance, and the optional features. Replace its placeholder Azure resource IDs, then run:

```shell
terraform plan -var-file=example.tfvars.json
```

## Testing

[`tests/baseline.tftest.hcl`](tests/baseline.tftest.hcl) checks the baseline and optional features against mocked providers, so it needs no Azure credentials:

```shell
terraform init -backend=false
terraform test
```

## API versions

- Managed cluster: `2026-06-01`, the first stable version that accepts Entra ID node SSH
- Agent pools: `2026-01-02-preview`
- Maintenance configurations: `2026-03-01`

AzAPI schema validation is disabled only for these resource blocks because AzAPI 2.9 does not embed these newer AKS schemas. Azure Resource Manager still validates every request during apply.
