resource "azapi_resource" "cluster" {
  type      = "Microsoft.ContainerService/managedClusters@2026-06-01"
  name      = var.name
  location  = var.location
  parent_id = var.resource_group_id
  tags      = var.tags

  body = {
    sku = {
      name = "Base"
      tier = var.sku_tier
    }
    properties = {
      aadProfile = {
        adminGroupObjectIDs = var.cluster_admin_group_object_ids
        enableAzureRBAC     = false
        managed             = true
      }
      addonProfiles     = local.addon_profiles
      agentPoolProfiles = [local.default_node_pool_properties]
      aiToolchainOperatorProfile = {
        enabled = var.kaito_enabled
      }
      apiServerAccessProfile = {
        enablePrivateCluster           = true
        enablePrivateClusterPublicFQDN = false
        enableVnetIntegration          = var.api_server_subnet_id != null
        privateDNSZone                 = var.private_dns_zone_id
        subnetId                       = var.api_server_subnet_id
      }
      autoScalerProfile = local.auto_scaler_profile
      autoUpgradeProfile = {
        nodeOSUpgradeChannel = var.node_os_upgrade_channel
      }
      diskEncryptionSetID = var.disk_encryption_set_id
      dnsPrefix           = var.name
      enableRBAC          = true
      identityProfile = {
        kubeletidentity = {
          resourceId = var.kubelet_identity_id
        }
      }
      kubernetesVersion = var.kubernetes_version
      networkProfile    = local.network_profile
      nodeProvisioningProfile = {
        mode = var.node_provisioning_mode
      }
      nodeResourceGroup = var.node_resource_group_name
      oidcIssuerProfile = {
        enabled = true
      }
      securityProfile = {
        azureKeyVaultKms = {
          enabled               = true
          keyId                 = var.key_vault_key_id
          keyVaultNetworkAccess = "Private"
          keyVaultResourceId    = var.key_vault_resource_id
        }
        workloadIdentity = {
          enabled = true
        }
      }
      supportPlan = var.support_plan
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.control_plane_identity_id]
  }

  ignore_null_property = true
  replace_triggers_refs = [
    "properties.nodeResourceGroup",
    "properties.agentPoolProfiles[0].vnetSubnetID",
  ]
  response_export_values = [
    "properties.currentKubernetesVersion",
    "properties.identityProfile.kubeletidentity",
    "properties.nodeResourceGroup",
    "properties.oidcIssuerProfile.issuerURL",
    "properties.privateFQDN",
  ]
  schema_validation_enabled = false

  dynamic "timeouts" {
    for_each = var.timeouts == null ? [] : [var.timeouts]

    content {
      create = timeouts.value.create
      delete = timeouts.value.delete
      read   = timeouts.value.read
      update = timeouts.value.update
    }
  }

  lifecycle {
    ignore_changes = [
      body.properties.agentPoolProfiles,
      body.properties.kubernetesVersion,
    ]
  }
}

resource "azapi_update_resource" "kubernetes_version" {
  type      = azapi_resource.cluster.type
  name      = var.name
  parent_id = var.resource_group_id
  body = {
    properties = {
      kubernetesVersion = var.kubernetes_version
    }
  }
  locks                  = [azapi_resource.cluster.id]
  response_export_values = []
}

resource "azapi_update_resource" "default_node_pool" {
  type      = "Microsoft.ContainerService/managedClusters/agentPools@2026-01-02-preview"
  name      = local.default_node_pool.name
  parent_id = azapi_resource.cluster.id
  body = {
    properties = local.default_node_pool_update_properties
  }
  locks                  = [azapi_resource.cluster.id]
  response_export_values = []

  depends_on = [azapi_update_resource.kubernetes_version]
}

resource "azapi_resource" "additional_node_pool" {
  for_each = local.additional_node_pool_properties

  type      = "Microsoft.ContainerService/managedClusters/agentPools@2026-01-02-preview"
  name      = each.key
  parent_id = azapi_resource.cluster.id
  body = {
    properties = each.value
  }
  ignore_null_property      = true
  locks                     = [azapi_resource.cluster.id]
  replace_triggers_refs     = ["properties.vmSize"]
  response_export_values    = ["properties.currentOrchestratorVersion", "properties.nodeImageVersion"]
  schema_validation_enabled = false

  dynamic "timeouts" {
    for_each = var.timeouts == null ? [] : [var.timeouts]

    content {
      create = timeouts.value.create
      delete = timeouts.value.delete
      read   = timeouts.value.read
      update = timeouts.value.update
    }
  }

  depends_on = [azapi_update_resource.default_node_pool]
}

resource "azapi_resource" "node_os_maintenance" {
  count = var.maintenance_window_node_os == null ? 0 : 1

  type      = "Microsoft.ContainerService/managedClusters/maintenanceConfigurations@2026-03-01"
  name      = "aksManagedNodeOSUpgradeSchedule"
  parent_id = azapi_resource.cluster.id
  body = {
    properties = {
      maintenanceWindow = {
        durationHours = var.maintenance_window_node_os.duration
        schedule = {
          weekly = {
            dayOfWeek     = var.maintenance_window_node_os.day_of_week
            intervalWeeks = var.maintenance_window_node_os.interval
          }
        }
        startTime = var.maintenance_window_node_os.start_time
        utcOffset = var.maintenance_window_node_os.utc_offset
      }
    }
  }
  response_export_values    = []
  schema_validation_enabled = false
}
