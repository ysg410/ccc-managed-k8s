locals {
  subscription_scope = join("/", slice(split("/", var.resource_group_id), 0, 3))
  pod_cidr           = "172.18.0.0/16"
  default_node_pool  = var.node_pools[0]
  additional_node_pools = {
    for pool in slice(var.node_pools, 1, length(var.node_pools)) : pool.name => pool
  }
  node_pool_sysctls = {
    for pool in var.node_pools : pool.name => pool.sysctl_config == null ? null : {
      for key, value in {
        fsAioMaxNr              = pool.sysctl_config.fs_aio_max_nr
        fsFileMax               = pool.sysctl_config.fs_file_max
        fsInotifyMaxUserWatches = pool.sysctl_config.fs_inotify_max_user_watches
        fsNrOpen                = pool.sysctl_config.fs_nr_open
        kernelThreadsMax        = pool.sysctl_config.kernel_threads_max
        netCoreNetdevMaxBacklog = pool.sysctl_config.net_core_netdev_max_backlog
        netCoreOptmemMax        = pool.sysctl_config.net_core_optmem_max
        netCoreRmemDefault      = pool.sysctl_config.net_core_rmem_default
        netCoreRmemMax          = pool.sysctl_config.net_core_rmem_max
        netCoreSomaxconn        = pool.sysctl_config.net_core_somaxconn
        netCoreWmemDefault      = pool.sysctl_config.net_core_wmem_default
        netCoreWmemMax          = pool.sysctl_config.net_core_wmem_max
        netIpv4IpLocalPortRange = (
          pool.sysctl_config.net_ipv4_ip_local_port_range_min == null ||
          pool.sysctl_config.net_ipv4_ip_local_port_range_max == null
          ) ? null : format(
          "%d %d",
          pool.sysctl_config.net_ipv4_ip_local_port_range_min,
          pool.sysctl_config.net_ipv4_ip_local_port_range_max,
        )
        netIpv4NeighDefaultGcThresh1   = pool.sysctl_config.net_ipv4_neigh_default_gc_thresh1
        netIpv4NeighDefaultGcThresh2   = pool.sysctl_config.net_ipv4_neigh_default_gc_thresh2
        netIpv4NeighDefaultGcThresh3   = pool.sysctl_config.net_ipv4_neigh_default_gc_thresh3
        netIpv4TcpFinTimeout           = pool.sysctl_config.net_ipv4_tcp_fin_timeout
        netIpv4TcpKeepaliveProbes      = pool.sysctl_config.net_ipv4_tcp_keepalive_probes
        netIpv4TcpKeepaliveTime        = pool.sysctl_config.net_ipv4_tcp_keepalive_time
        netIpv4TcpMaxSynBacklog        = pool.sysctl_config.net_ipv4_tcp_max_syn_backlog
        netIpv4TcpMaxTwBuckets         = pool.sysctl_config.net_ipv4_tcp_max_tw_buckets
        netIpv4TcpTwReuse              = pool.sysctl_config.net_ipv4_tcp_tw_reuse
        netIpv4TcpkeepaliveIntvl       = pool.sysctl_config.net_ipv4_tcp_keepalive_intvl
        netNetfilterNfConntrackBuckets = pool.sysctl_config.net_netfilter_nf_conntrack_buckets
        netNetfilterNfConntrackMax     = pool.sysctl_config.net_netfilter_nf_conntrack_max
        vmMaxMapCount                  = pool.sysctl_config.vm_max_map_count
        vmSwappiness                   = pool.sysctl_config.vm_swappiness
        vmVfsCachePressure             = pool.sysctl_config.vm_vfs_cache_pressure
      } : key => value if value != null
    }
  }

  default_node_labels = merge(
    coalesce(local.default_node_pool.node_labels, {}),
    local.default_node_pool.system_nodepool ? { "nodegroup-type" = "platform-only" } : {},
  )
  default_node_taints = concat(
    coalesce(local.default_node_pool.node_taints, []),
    local.default_node_pool.system_nodepool ? ["CriticalAddonsOnly=true:NoSchedule"] : [],
  )

  auto_scaler_profile = var.auto_scaler_profile == null || !anytrue([
    for pool in var.node_pools : pool.enable_auto_scaling
    ]) ? null : {
    balance-similar-node-groups      = var.auto_scaler_profile.balance_similar_node_groups
    expander                         = var.auto_scaler_profile.expander
    max-empty-bulk-delete            = var.auto_scaler_profile.empty_bulk_delete_max
    max-graceful-termination-sec     = var.auto_scaler_profile.max_graceful_termination_sec
    max-node-provision-time          = var.auto_scaler_profile.max_node_provisioning_time
    max-total-unready-percentage     = var.auto_scaler_profile.max_unready_percentage
    new-pod-scale-up-delay           = var.auto_scaler_profile.new_pod_scale_up_delay
    ok-total-unready-count           = var.auto_scaler_profile.max_unready_nodes
    scale-down-delay-after-add       = var.auto_scaler_profile.scale_down_delay_after_add
    scale-down-delay-after-delete    = var.auto_scaler_profile.scale_down_delay_after_delete
    scale-down-delay-after-failure   = var.auto_scaler_profile.scale_down_delay_after_failure
    scale-down-unneeded-time         = var.auto_scaler_profile.scale_down_unneeded
    scale-down-unready-time          = var.auto_scaler_profile.scale_down_unready
    scale-down-utilization-threshold = var.auto_scaler_profile.scale_down_utilization_threshold
    scan-interval                    = var.auto_scaler_profile.scan_interval
    skip-nodes-with-local-storage    = var.auto_scaler_profile.skip_nodes_with_local_storage
    skip-nodes-with-system-pods      = var.auto_scaler_profile.skip_nodes_with_system_pods
  }

  addon_profiles = {
    azurepolicy = {
      enabled = false
    }
    azureKeyvaultSecretsProvider = var.secrets_store_csi_driver_enabled ? {
      enabled = true
      config = {
        enableSecretRotation = "true"
      }
    } : null
  }

  network_profile = {
    advancedNetworking = var.acns_enabled ? {
      enabled = true
      observability = {
        enabled = true
      }
      security = {
        enabled = true
      }
    } : null
    dnsServiceIP      = var.dns_service_ip
    loadBalancerSku   = "standard"
    networkDataplane  = "cilium"
    networkMode       = "transparent"
    networkPlugin     = "azure"
    networkPluginMode = "overlay"
    networkPolicy     = "cilium"
    outboundType      = "userDefinedRouting"
    podCidr           = local.pod_cidr
    serviceCidr       = var.service_cidr
  }

  default_node_pool_properties = {
    availabilityZones          = local.default_node_pool.availability_zones
    capacityReservationGroupID = local.default_node_pool.capacity_reservation_group_id
    count                      = local.default_node_pool.enable_auto_scaling ? null : local.default_node_pool.node_count
    enableAutoScaling          = local.default_node_pool.enable_auto_scaling
    enableNodePublicIP         = false
    enableUltraSSD             = local.default_node_pool.ultra_ssd_enabled
    kubeletConfig = anytrue([
      local.default_node_pool.allowed_unsafe_sysctls != null,
      local.default_node_pool.topology_manager_policy != null,
      local.default_node_pool.cpu_cfs_quota_enabled != null,
      ]) ? {
      allowedUnsafeSysctls  = local.default_node_pool.allowed_unsafe_sysctls
      cpuCfsQuota           = local.default_node_pool.cpu_cfs_quota_enabled
      topologyManagerPolicy = local.default_node_pool.topology_manager_policy
    } : null
    linuxOSConfig = anytrue([
      local.default_node_pool.sysctl_config != null,
      local.default_node_pool.transparent_huge_page_enabled != null,
      local.default_node_pool.transparent_huge_page_defrag != null,
      ]) ? {
      sysctls                    = local.node_pool_sysctls[local.default_node_pool.name]
      transparentHugePageDefrag  = local.default_node_pool.transparent_huge_page_defrag
      transparentHugePageEnabled = local.default_node_pool.transparent_huge_page_enabled
    } : null
    maxCount            = local.default_node_pool.enable_auto_scaling ? local.default_node_pool.max_count : null
    maxPods             = local.default_node_pool.max_pods_per_node
    minCount            = local.default_node_pool.enable_auto_scaling ? local.default_node_pool.min_count : null
    mode                = "System"
    name                = local.default_node_pool.name
    nodeLabels          = local.default_node_labels
    nodeTaints          = local.default_node_taints
    orchestratorVersion = var.kubernetes_version
    osDiskSizeGB        = local.default_node_pool.os_disk_size_gb
    osDiskType          = local.default_node_pool.os_disk_type
    osSKU               = "Ubuntu"
    osType              = "Linux"
    securityProfile = {
      sshAccess = "EntraId"
    }
    tags = merge(var.tags, local.default_node_pool.tags)
    type = "VirtualMachineScaleSets"
    upgradeSettings = {
      maxSurge = local.default_node_pool.max_surge
    }
    vmSize       = local.default_node_pool.vm_size
    vnetSubnetID = var.subnet_id
  }

  additional_node_pool_properties = {
    for name, pool in local.additional_node_pools : name => {
      availabilityZones          = pool.availability_zones
      capacityReservationGroupID = pool.capacity_reservation_group_id
      count                      = pool.enable_auto_scaling ? null : pool.node_count
      enableAutoScaling          = pool.enable_auto_scaling
      enableNodePublicIP         = false
      enableUltraSSD             = pool.ultra_ssd_enabled
      kubeletConfig = anytrue([
        pool.allowed_unsafe_sysctls != null,
        pool.topology_manager_policy != null,
        pool.cpu_cfs_quota_enabled != null,
        ]) ? {
        allowedUnsafeSysctls  = pool.allowed_unsafe_sysctls
        cpuCfsQuota           = pool.cpu_cfs_quota_enabled
        topologyManagerPolicy = pool.topology_manager_policy
      } : null
      linuxOSConfig = anytrue([
        pool.sysctl_config != null,
        pool.transparent_huge_page_enabled != null,
        pool.transparent_huge_page_defrag != null,
        ]) ? {
        sysctls                    = local.node_pool_sysctls[name]
        transparentHugePageDefrag  = pool.transparent_huge_page_defrag
        transparentHugePageEnabled = pool.transparent_huge_page_enabled
      } : null
      maxCount = pool.enable_auto_scaling ? pool.max_count : null
      maxPods  = pool.max_pods_per_node
      minCount = pool.enable_auto_scaling ? pool.min_count : null
      mode     = "User"
      nodeLabels = coalesce(
        pool.node_labels,
        pool.priority == "Spot" ? { "kubernetes.azure.com/scalesetpriority" = "spot" } : {},
      )
      nodeTaints = coalesce(
        pool.node_taints,
        pool.priority == "Spot" ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : [],
      )
      orchestratorVersion    = var.kubernetes_version
      osDiskSizeGB           = pool.os_disk_size_gb
      osDiskType             = pool.os_disk_type
      osSKU                  = "Ubuntu"
      osType                 = "Linux"
      scaleSetEvictionPolicy = pool.priority == "Spot" ? pool.eviction_policy : null
      scaleSetPriority       = pool.priority
      securityProfile = {
        sshAccess = "EntraId"
      }
      spotMaxPrice = pool.priority == "Spot" ? pool.spot_max_price : null
      tags         = merge(var.tags, pool.tags)
      type         = "VirtualMachineScaleSets"
      upgradeSettings = pool.priority == "Spot" ? null : {
        maxSurge = pool.max_surge
      }
      vmSize       = pool.vm_size
      vnetSubnetID = coalesce(pool.subnet_id, var.subnet_id)
    }
  }

  default_node_pool_update_properties = merge(
    {
      for key, value in local.default_node_pool_properties : key => value
      if value != null && !contains(["kubeletConfig", "linuxOSConfig", "name", "upgradeSettings"], key)
    },
    local.default_node_pool_properties.kubeletConfig == null ? {} : {
      kubeletConfig = {
        for key, value in local.default_node_pool_properties.kubeletConfig : key => value if value != null
      }
    },
    local.default_node_pool_properties.linuxOSConfig == null ? {} : {
      linuxOSConfig = merge(
        {
          for key, value in local.default_node_pool_properties.linuxOSConfig : key => value
          if value != null && key != "sysctls"
        },
        local.default_node_pool_properties.linuxOSConfig.sysctls == null ? {} : {
          sysctls = local.default_node_pool_properties.linuxOSConfig.sysctls
        },
      )
    },
    {
      upgradeSettings = local.default_node_pool_properties.upgradeSettings
    },
  )
}
