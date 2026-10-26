# The outputs the shared CCC test scripts (workshop/aks/scripts/40, 50, 95) read.

output "cluster_name" {
  value = module.default.name
}

output "resource_group_name" {
  value = azapi_resource.resource_group.name
}

output "api_server_fqdn" {
  description = "Public API server FQDN (the example's cluster is not private)."
  value       = module.default.fqdn
}

output "oidc_issuer_url" {
  description = "Empty: the example does not enable the OIDC issuer."
  value       = module.default.oidc_issuer_profile_issuer_url == null ? "" : module.default.oidc_issuer_profile_issuer_url
}

output "log_analytics_workspace_id" {
  value = azapi_resource.log_analytics_workspace.id
}

output "container_registry_login_server" {
  value = azapi_resource.ccc_test_registry.output.properties.loginServer
}
