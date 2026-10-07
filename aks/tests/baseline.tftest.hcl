mock_provider "azapi" {}

variables {
  name               = "example-aks"
  location           = "eastus2"
  resource_group_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg"
  kubernetes_version = "1.32"

  private_dns_zone_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.eastus2.azmk8s.io"
  control_plane_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-mi"
  kubelet_identity_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/kubelet-mi"
  disk_encryption_set_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Compute/diskEncryptionSets/aks-des"
  key_vault_key_id          = "https://example.vault.azure.net/keys/aks-kms/00000000000000000000000000000000"
  key_vault_resource_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example"

  cluster_admin_group_object_ids = ["00000000-0000-0000-0000-000000000001"]
  subnet_id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/example-vnet/subnets/nodes"

  node_pools = [
    {
      name              = "system"
      vm_size           = "Standard_D4s_v5"
      node_count        = 3
      max_pods_per_node = 30
      system_nodepool   = true
    },
  ]
}

run "hardened_baseline" {
  command = plan

  assert {
    condition     = azapi_resource.cluster.type == "Microsoft.ContainerService/managedClusters@2026-06-01"
    error_message = "The managed cluster must use a stable API that supports Entra ID node SSH."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.apiServerAccessProfile.enablePrivateCluster
    error_message = "The API server must be private."
  }

  assert {
    condition     = !azapi_resource.cluster.body.properties.apiServerAccessProfile.enablePrivateClusterPublicFQDN
    error_message = "The private cluster must not expose a public FQDN."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.enableRBAC && !azapi_resource.cluster.body.properties.aadProfile.enableAzureRBAC
    error_message = "Kubernetes RBAC with managed Entra integration must be enabled."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.oidcIssuerProfile.enabled && azapi_resource.cluster.body.properties.securityProfile.workloadIdentity.enabled
    error_message = "OIDC and workload identity must be enabled."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.securityProfile.azureKeyVaultKms.enabled && azapi_resource.cluster.body.properties.securityProfile.azureKeyVaultKms.keyVaultNetworkAccess == "Private"
    error_message = "Private Key Vault KMS encryption must be enabled."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.diskEncryptionSetID == var.disk_encryption_set_id
    error_message = "The node disk encryption set must be configured."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.agentPoolProfiles[0].osSKU == "Ubuntu" && !azapi_resource.cluster.body.properties.agentPoolProfiles[0].enableNodePublicIP
    error_message = "The default pool must use Ubuntu without node public IPs."
  }

  assert {
    condition = alltrue([
      azapi_resource.cluster.body.properties.networkProfile.networkPlugin == "azure",
      azapi_resource.cluster.body.properties.networkProfile.networkPluginMode == "overlay",
      azapi_resource.cluster.body.properties.networkProfile.networkDataplane == "cilium",
      azapi_resource.cluster.body.properties.networkProfile.networkPolicy == "cilium",
      azapi_resource.cluster.body.properties.networkProfile.podCidr == "172.18.0.0/16",
      try(azapi_resource.cluster.body.properties.agentPoolProfiles[0].podSubnetID, null) == null,
    ])
    error_message = "The cluster must always use Azure CNI Overlay with Cilium and the fixed pod CIDR."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.agentPoolProfiles[0].securityProfile.sshAccess == "EntraId" && try(azapi_resource.cluster.body.properties.linuxProfile, null) == null
    error_message = "Nodes must use Microsoft Entra ID SSH without a generated SSH key."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.networkProfile.outboundType == "userDefinedRouting"
    error_message = "The cluster must use user-defined routing."
  }

  assert {
    condition     = try(azapi_resource.cluster.body.properties.disableLocalAccounts, null) == null && try(azapi_resource.cluster.body.properties.apiServerAccessProfile.disableRunCommand, null) == null
    error_message = "The module must not add controls outside its documented baseline."
  }
}

run "autoscaling_and_spot_pool" {
  command = plan

  variables {
    node_pools = [
      {
        name                = "system"
        vm_size             = "Standard_D4s_v5"
        max_pods_per_node   = 30
        system_nodepool     = true
        enable_auto_scaling = true
        min_count           = 3
        max_count           = 6
      },
      {
        name              = "spot"
        vm_size           = "Standard_D8s_v5"
        node_count        = 2
        max_pods_per_node = 50
        priority          = "Spot"
        eviction_policy   = "Delete"
        spot_max_price    = -1
      },
    ]
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.agentPoolProfiles[0].count == null && azapi_resource.cluster.body.properties.agentPoolProfiles[0].minCount == 3
    error_message = "Autoscaled pools must omit count and set their bounds."
  }

  assert {
    condition     = azapi_resource.additional_node_pool["spot"].body.properties.scaleSetPriority == "Spot" && azapi_resource.additional_node_pool["spot"].body.properties.scaleSetEvictionPolicy == "Delete"
    error_message = "Spot pool settings must map to the child agent pool resource."
  }

  assert {
    condition     = azapi_resource.additional_node_pool["spot"].body.properties.securityProfile.sshAccess == "EntraId" && azapi_update_resource.default_node_pool.body.properties.securityProfile.sshAccess == "EntraId"
    error_message = "Every node pool must use Microsoft Entra ID SSH."
  }
}

run "native_sysctl_types" {
  command = plan

  variables {
    node_pools = [
      {
        name              = "system"
        vm_size           = "Standard_D4s_v5"
        node_count        = 3
        max_pods_per_node = 30
        sysctl_config = {
          net_core_somaxconn               = 32768
          net_ipv4_ip_local_port_range_min = 32768
          net_ipv4_ip_local_port_range_max = 60999
          net_ipv4_tcp_tw_reuse            = true
        }
      },
    ]
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.agentPoolProfiles[0].linuxOSConfig.sysctls.netCoreSomaxconn == 32768
    error_message = "Numeric sysctls must remain numbers."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.agentPoolProfiles[0].linuxOSConfig.sysctls.netIpv4TcpTwReuse == true
    error_message = "Boolean sysctls must remain booleans."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.agentPoolProfiles[0].linuxOSConfig.sysctls.netIpv4IpLocalPortRange == "32768 60999"
    error_message = "The local port range must map to the ARM string representation."
  }
}

run "optional_features" {
  command = plan

  variables {
    api_server_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/example-vnet/subnets/api-server"
    acns_enabled                     = true
    kaito_enabled                    = true
    secrets_store_csi_driver_enabled = true
    node_os_upgrade_channel          = "NodeImage"
    maintenance_window_node_os = {
      interval    = 1
      day_of_week = "Wednesday"
      start_time  = "20:00"
      duration    = 8
      utc_offset  = "-04:00"
    }
    auto_scaler_profile = {
      empty_bulk_delete_max      = "20"
      max_node_provisioning_time = "20m"
      max_unready_nodes          = "4"
    }
    node_pools = [
      {
        name                = "system"
        vm_size             = "Standard_D4s_v5"
        max_pods_per_node   = 30
        enable_auto_scaling = true
        min_count           = 3
        max_count           = 6
      },
    ]
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.apiServerAccessProfile.enableVnetIntegration && azapi_resource.cluster.body.properties.apiServerAccessProfile.subnetId == var.api_server_subnet_id
    error_message = "Supplying an API server subnet must enable VNet integration."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.networkProfile.advancedNetworking.security.enabled && azapi_resource.cluster.body.properties.networkProfile.advancedNetworking.observability.enabled
    error_message = "ACNS must enable both security and observability."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.addonProfiles.azureKeyvaultSecretsProvider.config.enableSecretRotation == "true" && azapi_resource.cluster.body.properties.aiToolchainOperatorProfile.enabled
    error_message = "Optional CSI rotation and KAITO features must map to the cluster body."
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.autoScalerProfile["max-empty-bulk-delete"] == "20" && azapi_resource.cluster.body.properties.autoScalerProfile["max-node-provision-time"] == "20m" && azapi_resource.cluster.body.properties.autoScalerProfile["ok-total-unready-count"] == "4"
    error_message = "AzureRM autoscaler names must translate to their ARM equivalents."
  }

  assert {
    condition     = azapi_resource.node_os_maintenance[0].body.properties.maintenanceWindow.schedule.weekly.dayOfWeek == "Wednesday"
    error_message = "The weekly node OS maintenance schedule must map to the child resource."
  }
}
