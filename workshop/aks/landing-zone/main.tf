data "azurerm_client_config" "current" {}

data "azurerm_kubernetes_service_versions" "current" {
  location        = var.location
  include_preview = false
}

locals {
  name               = "${var.prefix}-aks-test"
  kubernetes_version = coalesce(var.kubernetes_version, data.azurerm_kubernetes_service_versions.current.latest_version)

  hub_cidr     = "10.10.0.0/16"
  fw_cidr      = "10.10.0.0/26"
  fw_mgmt_cidr = "10.10.0.64/26"
  jumpbox_cidr = "10.10.1.0/27"
  spoke_cidr   = "10.20.0.0/16"
  nodes_cidr   = "10.20.0.0/24"
  api_cidr     = "10.20.1.0/28"
  acr_pe_cidr  = "10.20.2.0/27"
  service_cidr = "10.100.0.0/16"
  dns_ip       = "10.100.0.10"
  # 172.18.0.0/16 is the pod CIDR hard-coded in the PR example; nothing here overlaps it.
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Entra admin group and deployer data-plane permission
# ---------------------------------------------------------------------------

resource "azuread_group" "aks_admins" {
  display_name     = "${local.name}-admins"
  security_enabled = true
  owners           = [data.azurerm_client_config.current.object_id]
  members          = [data.azurerm_client_config.current.object_id]
}

# ---------------------------------------------------------------------------
# Hub VNet: firewall and jumpbox (Terraform runner with access to the private API)
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${local.name}-hub"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  address_space       = [local.hub_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.fw_cidr]
}

resource "azurerm_subnet" "firewall_mgmt" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.fw_mgmt_cidr]
}

resource "azurerm_subnet" "jumpbox" {
  name                 = "snet-jumpbox"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.jumpbox_cidr]
}

# ---------------------------------------------------------------------------
# Spoke VNet: AKS nodes (UDR to firewall) and delegated API-server subnet
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${local.name}-spoke"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  address_space       = [local.spoke_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  name                            = "snet-aks-nodes"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.spoke.name
  address_prefixes                = [local.nodes_cidr]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "api_server" {
  name                            = "snet-aks-apiserver"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.spoke.name
  address_prefixes                = [local.api_cidr]
  default_outbound_access_enabled = false

  delegation {
    name = "aks-apiserver"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# The example's private container registry endpoint. The example links its
# privatelink.azurecr.io zone to this (cluster) VNet so nodes resolve it.
resource "azurerm_subnet" "acr_private_endpoint" {
  name                            = "snet-aks-endpoints"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.spoke.name
  address_prefixes                = [local.acr_pe_cidr]
  default_outbound_access_enabled = false
}

# Private DNS zone for workload hostnames (TraderX). external-dns, installed by
# 15-install-cluster-addons.sh, writes the records. Linked to the spoke so the
# cluster resolves them and to the hub so the jumpbox does.
resource "azurerm_private_dns_zone" "apps" {
  name                = var.app_dns_zone_name
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "apps" {
  for_each = {
    hub   = azurerm_virtual_network.hub.id
    spoke = azurerm_virtual_network.spoke.id
  }

  name                  = "${each.key}-vnet"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.apps.name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "hub-to-spoke"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "spoke-to-hub"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
}

# ---------------------------------------------------------------------------
# Optional Azure Firewall Basic for AKS egress (outboundType = userDefinedRouting).
# Off by default to save ~$0.40/hour: the cluster then uses outboundType =
# loadBalancer (the example's default) and egresses through its own public IP.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "firewall" {
  count = var.egress_firewall ? 1 : 0

  name                = "pip-${local.name}-fw"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_public_ip" "firewall_mgmt" {
  count = var.egress_firewall ? 1 : 0

  name                = "pip-${local.name}-fw-mgmt"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy" "this" {
  count = var.egress_firewall ? 1 : 0

  name                = "afwp-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku                 = "Basic"
  tags                = var.tags
}

# Firewall Basic has no DNS proxy, so FQDNs are only usable in application rules.
resource "azurerm_firewall_policy_rule_collection_group" "aks" {
  count = var.egress_firewall ? 1 : 0

  name               = "aks-egress"
  firewall_policy_id = azurerm_firewall_policy.this[0].id
  priority           = 200

  network_rule_collection {
    name     = "aks-network"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "ntp"
      protocols             = ["UDP"]
      source_addresses      = [local.nodes_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }
  }

  application_rule_collection {
    name     = "aks-application"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "aks-required"
      source_addresses      = [local.nodes_cidr]
      destination_fqdn_tags = ["AzureKubernetesService"]
      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }
    }

    rule {
      name              = "ubuntu-updates"
      source_addresses  = [local.nodes_cidr]
      destination_fqdns = ["security.ubuntu.com", "azure.archive.ubuntu.com", "changelogs.ubuntu.com", "snapshot.ubuntu.com"]
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
    }

    # Add-ons the example enables: Azure Policy, Container Insights (Entra auth)
    # and Defender. https://learn.microsoft.com/azure/aks/outbound-rules-control-egress
    rule {
      name             = "aks-addons"
      source_addresses = [local.nodes_cidr]
      destination_fqdns = [
        "data.policy.core.windows.net",
        "store.policy.core.windows.net",
        "dc.services.visualstudio.com",
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
        "*.monitoring.azure.com",
        "*.ingest.monitor.azure.com",
        "global.handler.control.monitor.azure.com",
        "${var.location}.handler.control.monitor.azure.com",
        "*.cloud.defender.microsoft.com",
        "login.microsoftonline.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # Optional: lets test workloads pull public images. Remove for a stricter test.
    rule {
      name              = "public-registries"
      source_addresses  = [local.nodes_cidr]
      destination_fqdns = ["ghcr.io", "pkg-containers.githubusercontent.com", "docker.io", "registry-1.docker.io", "production.cloudflare.docker.com", "auth.docker.io"]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }
}

resource "azurerm_firewall" "this" {
  count = var.egress_firewall ? 1 : 0

  name                = "afw-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Basic"
  firewall_policy_id  = azurerm_firewall_policy.this[0].id
  tags                = var.tags

  ip_configuration {
    name                 = "data"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }

  management_ip_configuration {
    name                 = "mgmt"
    subnet_id            = azurerm_subnet.firewall_mgmt.id
    public_ip_address_id = azurerm_public_ip.firewall_mgmt[0].id
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.aks]
}

resource "azurerm_route_table" "nodes" {
  count = var.egress_firewall ? 1 : 0

  name                          = "rt-${local.name}-nodes"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.location
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.this[0].ip_configuration[0].private_ip_address
  }

  route {
    name           = "firewall-public-ip"
    address_prefix = "${azurerm_public_ip.firewall[0].ip_address}/32"
    next_hop_type  = "Internet"
  }
}

resource "azurerm_subnet_route_table_association" "nodes" {
  count = var.egress_firewall ? 1 : 0

  subnet_id      = azurerm_subnet.nodes.id
  route_table_id = azurerm_route_table.nodes[0].id
}

# ---------------------------------------------------------------------------
# Inputs for examples/finos-ccc (written locally and onto the jumpbox)
# ---------------------------------------------------------------------------

locals {
  example_tfvars = {
    location                                      = var.location
    resource_group_id                             = azurerm_resource_group.this.id
    kubernetes_version                            = join(".", slice(split(".", local.kubernetes_version), 0, 2))
    cluster_admin_group_object_ids                = [azuread_group.aks_admins.object_id]
    subnet_id                                     = azurerm_subnet.nodes.id
    api_server_subnet_id                          = azurerm_subnet.api_server.id
    container_registry_private_endpoint_subnet_id = azurerm_subnet.acr_private_endpoint.id
    # AKS runs the cluster on its newer KMS experience (PMK) at the latest Kubernetes
    # versions, which rejects a versioned key URL.
    kms_key_versionless = true
    # AVM telemetry records the apply time on every run; off so the idempotency
    # check in 10-run-example.sh covers only real resources (as the example documents).
    enable_telemetry = false
    outbound_type    = var.egress_firewall ? "userDefinedRouting" : "loadBalancer"
    service_cidr     = local.service_cidr
    dns_service_ip   = local.dns_ip
    tags             = var.tags
    # No AKS managed namespaces (the example's default creates workload-a, with its
    # workload identity, as an ARM resource). Workshop namespaces are plain Kubernetes ones.
    workload_namespaces = {}

    # Declared by ../example/workshop_variables.tf in the jumpbox's clone.
    workshop_node_vm_size           = var.aks_node_vm_size
    workshop_node_count             = var.aks_node_count
    workshop_node_max_count         = var.aks_node_max_count
    workshop_node_max_pods          = var.aks_node_max_pods
    workshop_node_zones             = var.aks_node_zones
    workshop_aks_sku_tier           = var.aks_sku_tier
    workshop_azure_policy_enabled   = var.aks_azure_policy_enabled
    workshop_defender_enabled       = var.aks_defender_enabled
    workshop_monitoring_enabled     = var.aks_monitoring_enabled
    workshop_container_registry_sku = var.aks_container_registry_sku
    # Declared by ../example/workshop_variables.tf; used by workshop_external_dns.tf.
    workshop_app_dns_zone_id = azurerm_private_dns_zone.apps.id
  }

  example_tfvars_json = jsonencode(local.example_tfvars)
}

resource "local_file" "example_tfvars" {
  filename        = "${path.module}/generated/terraform.tfvars.json"
  content         = local.example_tfvars_json
  file_permission = "0600"
}
