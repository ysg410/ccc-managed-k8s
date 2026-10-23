# Applies workshop_variables.tf to the AVM AKS example (examples/finos-ccc). NOT
# part of the example. Terraform merges override files over the example's blocks:
# https://developer.hashicorp.com/terraform/language/files/override
# Each value below mirrors the example at bb2fa8d with the workshop variables
# substituted, so the example's defaults apply when the variables are not set.

locals {
  enabled_cluster_features = {
    azure_key_vault_kms = true
    azure_policy        = var.workshop_azure_policy_enabled
    defender            = var.workshop_defender_enabled
    image_cleaner       = true
    oms_agent           = var.workshop_monitoring_enabled
    workload_identity   = true
  }
}

module "aks" {
  addon_profile_oms_agent = var.workshop_monitoring_enabled ? {
    enabled = true
    config = {
      log_analytics_workspace_resource_id = module.log_analytics.resource_id
      use_aad_auth                        = true
    }
  } : null
  default_agent_pool = {
    name                      = "systempool"
    vm_size                   = var.workshop_node_vm_size
    count_of                  = var.workshop_node_count
    min_count                 = var.workshop_node_count
    max_count                 = var.workshop_node_max_count
    max_pods                  = var.workshop_node_max_pods
    vnet_subnet_id            = local.node_subnet_id
    os_sku                    = "Ubuntu"
    os_disk_type              = "Managed"
    enable_auto_scaling       = true
    enable_encryption_at_host = true
    enable_node_public_ip     = false
    availability_zones        = var.workshop_node_zones
    security_profile = {
      enable_secure_boot = true
      enable_vtpm        = true
      ssh_access         = "Disabled"
    }
  }
  diagnostic_settings = {
    for name, setting in {
      log_analytics = {
        name                           = "ds-aks-ccc"
        workspace_resource_id          = module.log_analytics.resource_id
        log_analytics_destination_type = "Dedicated"
        log_groups                     = ["allLogs"]
      }
    } : name => setting if var.workshop_monitoring_enabled
  }
  # The Defender block must be absent, not just disabled, when Defender is off.
  security_profile = {
    workload_identity = {
      enabled = true
    }
    azure_key_vault_kms = {
      enabled                  = true
      key_id                   = local.key_vault_key_id
      key_vault_network_access = "Private"
      key_vault_resource_id    = local.key_vault_resource_id
    }
    defender = var.workshop_defender_enabled ? {
      log_analytics_workspace_resource_id = module.log_analytics.resource_id
      security_monitoring = {
        enabled = true
      }
    } : null
    image_cleaner = {
      enabled        = true
      interval_hours = 48
    }
  }
  sku = {
    name = "Base"
    tier = var.workshop_aks_sku_tier
  }
}

module "policy_restricted_pod_security" {
  count = var.workshop_azure_policy_enabled ? 1 : 0
}

module "policy_allowed_images" {
  count = var.workshop_azure_policy_enabled ? 1 : 0
}

module "policy_resource_limits" {
  count = var.workshop_azure_policy_enabled ? 1 : 0
}

module "container_registry" {
  private_endpoints = {
    for name, endpoint in {
      cluster = {
        name                          = "pe-ccc-acr-${random_string.name_suffix.result}"
        subnet_resource_id            = local.container_registry_private_endpoint_subnet_id
        private_dns_zone_resource_ids = [local.container_registry_private_dns_zone_id]
      }
    } : name => endpoint if var.workshop_container_registry_sku == "Premium"
  }
  public_network_access_enabled = var.workshop_container_registry_sku != "Premium"
  sku                           = var.workshop_container_registry_sku
  zone_redundancy_enabled       = var.workshop_container_registry_sku == "Premium"
}
