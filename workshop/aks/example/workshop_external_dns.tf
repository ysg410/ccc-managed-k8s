# Workload identity for external-dns. NOT part of the AVM example: 10-run-example.sh
# copies this file into the jumpbox's clone, and 15-install-cluster-addons.sh installs
# external-dns with it. Created only when the landing zone passes its private DNS zone
# (workshop_app_dns_zone_id), so the example is unchanged without it.

locals {
  workshop_app_dns_zone = var.workshop_app_dns_zone_id == null ? {} : {
    this = provider::azapi::parse_resource_id("Microsoft.Network/privateDnsZones", var.workshop_app_dns_zone_id)
  }
}

resource "azurerm_user_assigned_identity" "workshop_external_dns" {
  for_each = local.workshop_app_dns_zone

  name                = "id-ccc-external-dns-${random_string.name_suffix.result}"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

# The external-dns service account (namespace external-dns) exchanges its token for this identity.
resource "azurerm_federated_identity_credential" "workshop_external_dns" {
  for_each = local.workshop_app_dns_zone

  name                      = "external-dns"
  user_assigned_identity_id = azurerm_user_assigned_identity.workshop_external_dns[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_profile_issuer_url
  subject                   = "system:serviceaccount:external-dns:external-dns"
}

# The minimum external-dns documents for Azure Private DNS: write records in the zone,
# and read the resource group to find the zone.
resource "azurerm_role_assignment" "workshop_external_dns_zone" {
  for_each = local.workshop_app_dns_zone

  scope                = var.workshop_app_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.workshop_external_dns[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "workshop_external_dns_reader" {
  for_each = local.workshop_app_dns_zone

  scope                = "/subscriptions/${each.value.subscription_id}/resourceGroups/${each.value.resource_group_name}"
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.workshop_external_dns[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

output "workshop_external_dns_client_id" {
  description = "Client ID of the external-dns workload identity (null without workshop_app_dns_zone_id)."
  value       = try(azurerm_user_assigned_identity.workshop_external_dns["this"].client_id, null)
}
