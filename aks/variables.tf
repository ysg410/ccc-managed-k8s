variable "name" {
  description = "Name of the AKS managed cluster."
  type        = string
}

variable "location" {
  description = "Azure region in which to create the cluster."
  type        = string
}

variable "resource_group_id" {
  description = "Resource ID of the existing resource group that will contain the cluster."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+$", var.resource_group_id))
    error_message = "resource_group_id must be a resource group resource ID."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the control plane and node pools."
  type        = string
}

variable "sku_tier" {
  description = "AKS SKU tier."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard, or Premium."
  }
}

variable "support_plan" {
  description = "AKS support plan."
  type        = string
  default     = "KubernetesOfficial"

  validation {
    condition     = contains(["KubernetesOfficial", "AKSLongTermSupport"], var.support_plan)
    error_message = "support_plan must be KubernetesOfficial or AKSLongTermSupport."
  }
}

variable "node_resource_group_name" {
  description = "Name of the AKS-managed node resource group. Azure generates a name when null."
  type        = string
  default     = null
}

variable "private_dns_zone_id" {
  description = "Resource ID of the existing private DNS zone used by the private AKS API server."
  type        = string
}

variable "control_plane_identity_id" {
  description = "Resource ID of the user-assigned managed identity used by the AKS control plane."
  type        = string
}

variable "kubelet_identity_id" {
  description = "Resource ID of the user-assigned managed identity used by kubelets."
  type        = string
}

variable "disk_encryption_set_id" {
  description = "Resource ID of the disk encryption set used for node OS disks."
  type        = string
}

variable "key_vault_key_id" {
  description = "Versioned Key Vault key identifier used for Kubernetes secret encryption."
  type        = string
}

variable "key_vault_resource_id" {
  description = "Resource ID of the Key Vault containing key_vault_key_id. Required for private KMS access."
  type        = string
}

variable "cluster_admin_group_object_ids" {
  description = "Microsoft Entra group object IDs granted Kubernetes cluster-admin access."
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_group_object_ids) > 0
    error_message = "At least one cluster administrator group is required."
  }
}

variable "subnet_id" {
  description = "Resource ID of the subnet used by the default node pool."
  type        = string
}

variable "api_server_subnet_id" {
  description = "Optional resource ID of the delegated subnet used for API server VNet integration."
  type        = string
  default     = null
}

variable "dns_service_ip" {
  description = "IP address used by the Kubernetes DNS service."
  type        = string
  default     = "172.16.0.53"
}

variable "service_cidr" {
  description = "CIDR used by Kubernetes services."
  type        = string
  default     = "172.16.0.0/16"
}

variable "acns_enabled" {
  description = "Enable Advanced Container Networking Services security and observability features."
  type        = bool
  default     = false
}

variable "secrets_store_csi_driver_enabled" {
  description = "Enable the Azure Key Vault Secrets Store CSI Driver with secret rotation."
  type        = bool
  default     = false
}

variable "kaito_enabled" {
  description = "Enable the AKS AI Toolchain Operator profile."
  type        = bool
  default     = false
}

variable "node_os_upgrade_channel" {
  description = "Node OS upgrade channel, for example NodeImage for automatic node image upgrades."
  type        = string
  default     = "None"

  validation {
    condition     = contains(["None", "NodeImage", "SecurityPatch", "Unmanaged"], var.node_os_upgrade_channel)
    error_message = "node_os_upgrade_channel must be None, NodeImage, SecurityPatch, or Unmanaged."
  }
}

variable "maintenance_window_node_os" {
  description = "Optional weekly maintenance schedule for node OS upgrades."
  type = object({
    interval    = number
    day_of_week = string
    start_time  = string
    duration    = number
    utc_offset  = string
  })
  default = null
}

variable "node_provisioning_mode" {
  description = "AKS node auto-provisioning mode."
  type        = string
  default     = "Manual"

  validation {
    condition     = contains(["Manual", "Auto"], var.node_provisioning_mode)
    error_message = "node_provisioning_mode must be Manual or Auto."
  }
}

variable "auto_scaler_profile" {
  description = "Optional cluster autoscaler profile. Values map to AKS autoscaler settings."
  type = object({
    expander                         = optional(string)
    scan_interval                    = optional(string)
    empty_bulk_delete_max            = optional(string)
    balance_similar_node_groups      = optional(string)
    max_graceful_termination_sec     = optional(string)
    max_node_provisioning_time       = optional(string)
    max_unready_nodes                = optional(string)
    max_unready_percentage           = optional(string)
    new_pod_scale_up_delay           = optional(string)
    scale_down_delay_after_add       = optional(string)
    scale_down_delay_after_delete    = optional(string)
    scale_down_delay_after_failure   = optional(string)
    scale_down_unneeded              = optional(string)
    scale_down_unready               = optional(string)
    scale_down_utilization_threshold = optional(string)
    skip_nodes_with_local_storage    = optional(string)
    skip_nodes_with_system_pods      = optional(string)
  })
  default = null
}

variable "node_pools" {
  description = "Node pool configurations. The first entry is the default system pool."
  type = list(object({
    name                    = string
    vm_size                 = string
    node_count              = optional(number)
    os_disk_size_gb         = optional(number)
    os_disk_type            = optional(string, "Managed")
    max_pods_per_node       = number
    ultra_ssd_enabled       = optional(bool)
    node_labels             = optional(map(string))
    availability_zones      = optional(list(string), ["1", "2", "3"])
    node_taints             = optional(list(string))
    system_nodepool         = optional(bool, false)
    allowed_unsafe_sysctls  = optional(list(string))
    topology_manager_policy = optional(string)
    cpu_cfs_quota_enabled   = optional(bool)
    sysctl_config = optional(object({
      fs_aio_max_nr                      = optional(number)
      fs_file_max                        = optional(number)
      fs_inotify_max_user_watches        = optional(number)
      fs_nr_open                         = optional(number)
      kernel_threads_max                 = optional(number)
      net_core_netdev_max_backlog        = optional(number)
      net_core_optmem_max                = optional(number)
      net_core_rmem_default              = optional(number)
      net_core_rmem_max                  = optional(number)
      net_core_somaxconn                 = optional(number)
      net_core_wmem_default              = optional(number)
      net_core_wmem_max                  = optional(number)
      net_ipv4_ip_local_port_range_max   = optional(number)
      net_ipv4_ip_local_port_range_min   = optional(number)
      net_ipv4_neigh_default_gc_thresh1  = optional(number)
      net_ipv4_neigh_default_gc_thresh2  = optional(number)
      net_ipv4_neigh_default_gc_thresh3  = optional(number)
      net_ipv4_tcp_fin_timeout           = optional(number)
      net_ipv4_tcp_keepalive_intvl       = optional(number)
      net_ipv4_tcp_keepalive_probes      = optional(number)
      net_ipv4_tcp_keepalive_time        = optional(number)
      net_ipv4_tcp_max_syn_backlog       = optional(number)
      net_ipv4_tcp_max_tw_buckets        = optional(number)
      net_ipv4_tcp_tw_reuse              = optional(bool)
      net_netfilter_nf_conntrack_buckets = optional(number)
      net_netfilter_nf_conntrack_max     = optional(number)
      vm_max_map_count                   = optional(number)
      vm_swappiness                      = optional(number)
      vm_vfs_cache_pressure              = optional(number)
    }))
    transparent_huge_page_enabled = optional(string)
    transparent_huge_page_defrag  = optional(string)
    subnet_id                     = optional(string)
    enable_auto_scaling           = optional(bool, false)
    min_count                     = optional(number)
    max_count                     = optional(number)
    max_surge                     = optional(string, "1")
    tags                          = optional(map(string), {})
    priority                      = optional(string, "Regular")
    eviction_policy               = optional(string)
    spot_max_price                = optional(number)
    capacity_reservation_group_id = optional(string)
  }))

  validation {
    condition     = length(var.node_pools) > 0
    error_message = "At least one node pool is required."
  }

  validation {
    condition     = length(distinct([for pool in var.node_pools : pool.name])) == length(var.node_pools)
    error_message = "Node pool names must be unique."
  }

  validation {
    condition     = alltrue([for pool in var.node_pools : can(regex("^[a-z][a-z0-9]{0,11}$", pool.name))])
    error_message = "Node pool names must begin with a lowercase letter and contain at most 12 lowercase alphanumeric characters."
  }

  validation {
    condition = alltrue([
      for pool in var.node_pools :
      pool.enable_auto_scaling ? pool.min_count != null && pool.max_count != null : pool.node_count != null
    ])
    error_message = "Autoscaled pools require min_count and max_count; fixed-size pools require node_count."
  }

  validation {
    condition     = alltrue([for pool in var.node_pools : contains(["Regular", "Spot"], pool.priority)])
    error_message = "Node pool priority must be Regular or Spot."
  }

  validation {
    condition     = var.node_pools[0].priority == "Regular"
    error_message = "The default system node pool must use Regular priority."
  }
}

variable "tags" {
  description = "Tags applied to the cluster and, unless overridden, its node pools."
  type        = map(string)
  default     = {}
}

variable "timeouts" {
  description = "Optional AzAPI timeouts for cluster and agent pool operations."
  type = object({
    create = optional(string)
    delete = optional(string)
    read   = optional(string)
    update = optional(string)
  })
  default = null
}
