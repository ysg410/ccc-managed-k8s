output "cluster_id" {
  description = "Resource ID of the AKS cluster."
  value       = azapi_resource.cluster.id
}

output "cluster_name" {
  description = "Name of the AKS cluster."
  value       = azapi_resource.cluster.name
}

output "private_fqdn" {
  description = "Private FQDN of the AKS API server."
  value       = try(azapi_resource.cluster.output.properties.privateFQDN, null)
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL used by workload identity federation."
  value       = try(azapi_resource.cluster.output.properties.oidcIssuerProfile.issuerURL, null)
}

output "current_kubernetes_version" {
  description = "Full Kubernetes version currently running on the cluster."
  value       = try(azapi_resource.cluster.output.properties.currentKubernetesVersion, null)
}

output "node_resource_group_name" {
  description = "Name of the AKS-managed node resource group."
  value       = try(azapi_resource.cluster.output.properties.nodeResourceGroup, null)
}

output "node_resource_group_id" {
  description = "Resource ID of the AKS-managed node resource group."
  value = try(
    "${local.subscription_scope}/resourceGroups/${azapi_resource.cluster.output.properties.nodeResourceGroup}",
    null,
  )
}

output "kubelet_identity" {
  description = "Kubelet identity returned by AKS."
  value       = try(azapi_resource.cluster.output.properties.identityProfile.kubeletidentity, null)
}

output "additional_node_pool_ids" {
  description = "Resource IDs of additional node pools keyed by pool name."
  value       = { for name, pool in azapi_resource.additional_node_pool : name => pool.id }
}
