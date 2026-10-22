output "jumpbox_ssh" {
  description = "SSH command for the jumpbox."
  value       = "ssh azureuser@${azurerm_public_ip.jumpbox.ip_address}"
}

output "resource_group_id" {
  value = azurerm_resource_group.this.id
}

output "aks_admin_group_object_id" {
  value = azuread_group.aks_admins.object_id
}

output "firewall_private_ip" {
  value = try(azurerm_firewall.this[0].ip_configuration[0].private_ip_address, null)
}

output "kubernetes_version" {
  value = local.kubernetes_version
}

output "example_tfvars_path" {
  description = "Generated inputs for examples/finos-ccc (also copied onto the jumpbox)."
  value       = abspath(local_file.example_tfvars.filename)
}
