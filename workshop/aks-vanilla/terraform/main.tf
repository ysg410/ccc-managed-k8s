# The AVM AKS module's published `default` example at v0.8.5
# (https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster/tree/v0.8.5/examples/default),
# taken from the Terraform Registry instead of the repository and changed only where
# marked "Workshop:". No CCC controls are added: this is the baseline the CCC tests
# compare against the hardened examples/finos-ccc cluster.

provider "azapi" {
  # Workshop: pin the workshop subscription instead of the az CLI default.
  subscription_id = var.subscription_id
}

# Workshop: the example picks a random region from the avm-utl-regions module, filtered
# to northeurope; the workshop uses its own region (var.location) instead.
locals {
  location = var.location
}

# This ensures we have unique CAF compliant names for our resources.
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.4"
}

data "azapi_client_config" "current" {}

# This is required for resource modules
resource "azapi_resource" "resource_group" {
  location               = local.location
  name                   = module.naming.resource_group.name_unique
  parent_id              = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  type                   = "Microsoft.Resources/resourceGroups@2024-03-01"
  response_export_values = []
}

resource "azapi_resource" "log_analytics_workspace" {
  location  = azapi_resource.resource_group.location
  name      = module.naming.log_analytics_workspace.name_unique
  parent_id = azapi_resource.resource_group.id
  type      = "Microsoft.OperationalInsights/workspaces@2023-09-01"
  body = {
    properties = {
      retentionInDays = 30
      sku = {
        name = "PerGB2018"
      }
    }
  }
  response_export_values = []
}

# This is the module call.
# Use the resource group location selected above so the module and prerequisites deploy together.
module "default" {
  # Workshop: the published module (the example uses source = "../..").
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.8.5"

  location  = azapi_resource.resource_group.location
  name      = module.naming.kubernetes_cluster.name_unique
  parent_id = azapi_resource.resource_group.id
  aad_profile = {
    enable_azure_rbac = true
    tenant_id         = data.azapi_client_config.current.tenant_id
    # Workshop: the landing zone's admin group, so you (and the CCC tests) get kubectl
    # access. The example leaves this empty, which grants nobody Kubernetes access.
    admin_group_object_ids = var.cluster_admin_group_object_ids
    managed                = true
  }
  addon_profile_oms_agent = {
    enabled = true
    config = {
      log_analytics_workspace_resource_id = azapi_resource.log_analytics_workspace.id
      use_aad_auth                        = true
    }
  }
  auto_upgrade_profile = {
    upgrade_channel = "none"
  }
  default_agent_pool = {
    # Workshop: the same nodes as the hardened workshop cluster (example: 1 x Standard_B2s_v2).
    count_of = var.node_count
    vm_size  = var.node_vm_size

    upgrade_settings = {
      max_surge = "10%"
    }
  }
  diagnostic_settings = {
    to_la = {
      name                  = "to-la"
      workspace_resource_id = azapi_resource.log_analytics_workspace.id
    }
  }
  dns_prefix       = "defaultexample"
  enable_telemetry = var.enable_telemetry
  managed_identities = {
    system_assigned = true
  }
  sku = {
    tier = "Standard"
    name = "Base"
  }
}
