# Workshop settings for the AVM AKS example (examples/finos-ccc). NOT part of the
# example: 10-run-example.sh copies this file and workshop_override.tf into the
# jumpbox's clone. The defaults are the example's own settings; the landing zone
# passes the workshop values from landing-zone/workshop.auto.tfvars.json.

variable "workshop_node_vm_size" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "VM size of the default node pool."
  nullable    = false
}

variable "workshop_node_count" {
  type        = number
  default     = 2
  description = "Initial and minimum node count of the default node pool."
  nullable    = false
}

variable "workshop_node_max_count" {
  type        = number
  default     = 5
  description = "Autoscaler maximum of the default node pool. Set it to workshop_node_count to pin the pool size within a small vCPU quota."
  nullable    = false
}

variable "workshop_node_zones" {
  type        = list(string)
  default     = ["1", "2", "3"]
  description = "Availability zones of the default node pool. Use only zones not restricted for the subscription."
  nullable    = false
}

variable "workshop_aks_sku_tier" {
  type        = string
  default     = "Standard"
  description = "AKS tier: Standard (uptime SLA) or Free."
  nullable    = false

  validation {
    condition     = contains(["Free", "Standard"], var.workshop_aks_sku_tier)
    error_message = "workshop_aks_sku_tier must be Free or Standard."
  }
}

variable "workshop_azure_policy_enabled" {
  type        = bool
  default     = true
  description = "Azure Policy add-on and the example's deny-mode assignments (restricted pod security, approved registry with digests, container limits). False lets public, unpinned images such as TraderX run."
  nullable    = false
}

variable "workshop_defender_enabled" {
  type        = bool
  default     = true
  description = "Microsoft Defender for Containers threat detection (billed per node vCPU)."
  nullable    = false
}

variable "workshop_monitoring_enabled" {
  type        = bool
  default     = true
  description = "Container Insights and AKS diagnostic logs to Log Analytics (billed per GB ingested). The workspace is created either way."
  nullable    = false
}

variable "workshop_container_registry_sku" {
  type        = string
  default     = "Premium"
  description = "Container registry SKU. Premium is private (private endpoint) and zone redundant; Basic and Standard have no private endpoints, so the registry is public."
  nullable    = false

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.workshop_container_registry_sku)
    error_message = "workshop_container_registry_sku must be Basic, Standard or Premium."
  }
}
