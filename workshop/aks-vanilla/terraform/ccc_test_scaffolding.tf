# Test scaffolding outside the cluster, NOT part of the AVM example: the CCC test setup
# pushes its admission-webhook probe image to a registry the cluster can pull from.
# A Basic registry plus AcrPull for the kubelet identity; the cluster is unchanged.

resource "azapi_resource" "ccc_test_registry" {
  location  = azapi_resource.resource_group.location
  name      = module.naming.container_registry.name_unique
  parent_id = azapi_resource.resource_group.id
  type      = "Microsoft.ContainerRegistry/registries@2023-07-01"
  body = {
    sku = {
      name = "Basic"
    }
    properties = {
      adminUserEnabled = false
    }
  }
  response_export_values = ["properties.loginServer"]
}

resource "azapi_resource" "ccc_test_registry_acr_pull" {
  name      = uuidv5("url", "${azapi_resource.ccc_test_registry.id}/AcrPull/${module.default.kubelet_identity.objectId}")
  parent_id = azapi_resource.ccc_test_registry.id
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  body = {
    properties = {
      # AcrPull
      roleDefinitionId = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d"
      principalId      = module.default.kubelet_identity.objectId
      principalType    = "ServicePrincipal"
    }
  }
  response_export_values = []
}
