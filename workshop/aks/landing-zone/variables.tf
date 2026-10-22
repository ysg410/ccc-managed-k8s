variable "subscription_id" {
  description = "Target subscription ID."
  type        = string
}

variable "location" {
  description = "Region where aks_node_vm_size and jumpbox_vm_size are available (00-preflight.sh checks this). Lowercase, no spaces (it is used in the AKS private DNS zone name)."
  type        = string
  default     = "centralindia"

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "Use the short region name, for example centralindia, not \"Central India\"."
  }
}

variable "prefix" {
  description = "Short prefix for resource names."
  type        = string
  default     = "ccc"
}

variable "admin_ssh_source_cidr" {
  description = "Your public IP as a /32 CIDR. Only this address can SSH to the jumpbox."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_ssh_source_cidr, 0)) && var.admin_ssh_source_cidr != "0.0.0.0/0"
    error_message = "Provide a specific CIDR such as 203.0.113.10/32."
  }
}

variable "ssh_public_key_path" {
  description = "Path to an RSA SSH public key for the jumpbox admin user."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "jumpbox_vm_size" {
  description = "Jumpbox VM size. Counts against the same regional vCPU quota as the AKS nodes."
  type        = string
  default     = "Standard_B2als_v2"
}

# Settings for the AVM AKS example, passed to it as workshop_* variables (see
# ../example/workshop_variables.tf). Defaults are the example's own settings; the
# workshop's low-cost values are in workshop.auto.tfvars.json.
variable "aks_node_vm_size" {
  description = "VM size of the example's default node pool."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "aks_node_count" {
  description = "Initial and minimum node count of the example's default node pool."
  type        = number
  default     = 2
}

variable "aks_node_max_count" {
  description = "Autoscaler maximum of the example's default node pool."
  type        = number
  default     = 5
}

variable "aks_node_zones" {
  description = "Availability zones of the example's default node pool. Only zones not restricted for the subscription work."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "aks_sku_tier" {
  description = "AKS tier: Standard (uptime SLA, ~$0.10/hour) or Free."
  type        = string
  default     = "Standard"
}

variable "aks_azure_policy_enabled" {
  description = "Azure Policy add-on and the example's deny-mode assignments. Must be false for TraderX, whose public, unpinned images and pod specs those policies reject."
  type        = bool
  default     = true
}

variable "aks_defender_enabled" {
  description = "Microsoft Defender for Containers threat detection (billed per node vCPU)."
  type        = bool
  default     = true
}

variable "aks_monitoring_enabled" {
  description = "Container Insights and AKS diagnostic logs to Log Analytics (billed per GB ingested)."
  type        = bool
  default     = true
}

variable "aks_container_registry_sku" {
  description = "Container registry SKU: Premium (private endpoint, zone redundant, ~$0.07/hour) or Basic/Standard (public)."
  type        = string
  default     = "Premium"
}

variable "egress_firewall" {
  description = "Route AKS egress through Azure Firewall Basic (outboundType userDefinedRouting, ~$0.40/hour). False uses the cluster's own load balancer for egress (outboundType loadBalancer)."
  type        = bool
  default     = false
}

variable "traderx_manifest_path" {
  description = "Path to the TraderX Kubernetes manifest copied to /opt/aks-ccc/traderx.yaml on the jumpbox for 30-deploy-traderx.sh. Null uses this repository's examples/traderx/traderx-aks-demo.yaml."
  type        = string
  default     = null
}

variable "kubernetes_version" {
  description = "Kubernetes version for the example, for example 1.33 (a patch, if given, is dropped: the example takes <major.minor>). Null picks the latest GA version in the region."
  type        = string
  default     = null
}

variable "example_repo_url" {
  description = "Repository containing the PR branch."
  type        = string
  default     = "https://github.com/ysg410/terraform-azurerm-avm-res-containerservice-managedcluster.git"
}

variable "example_repo_branch" {
  description = "PR branch to test."
  type        = string
  default     = "feat/finos-ccc-example"
}

variable "tags" {
  description = "Tags applied to landing-zone resources and passed to the example. The example requires environment, owner and data-classification (CCC.K8S.CN15.AR01)."
  type        = map(string)
  default = {
    environment         = "test"
    owner               = "platform-team"
    data-classification = "internal"
    purpose             = "avm-aks-pr-333"
  }

  validation {
    condition     = alltrue([for key in ["environment", "owner", "data-classification"] : contains(keys(var.tags), key)])
    error_message = "tags must include environment, owner and data-classification (required by the example)."
  }
}
