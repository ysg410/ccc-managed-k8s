variable "enable_telemetry" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
}

# Workshop inputs, written to terraform.tfvars.json by scripts/05-sync-jumpbox.sh.

variable "subscription_id" {
  type        = string
  description = "Workshop subscription."
}

variable "location" {
  type        = string
  description = "Workshop region (the landing zone's location)."
}

variable "cluster_admin_group_object_ids" {
  type        = list(string)
  description = "Entra groups with cluster-admin (the landing zone's AKS admin group)."
}

variable "node_count" {
  type        = number
  default     = 2
  description = "Node count of the default node pool (same as the hardened workshop cluster)."
}

variable "node_vm_size" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "VM size of the default node pool (same as the hardened workshop cluster)."
}
