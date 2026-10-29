# Jumpbox in the hub VNet. Terraform for the AKS example must run from here: the
# example's Key Vault has public access disabled and the AKS API is private.

resource "azurerm_public_ip" "jumpbox" {
  name                = "pip-${local.name}-jumpbox"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_security_group" "jumpbox" {
  name                = "nsg-${local.name}-jumpbox"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "ssh-from-admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_ssh_source_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-${local.name}-jumpbox"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.jumpbox.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }
}

resource "azurerm_network_interface_security_group_association" "jumpbox" {
  network_interface_id      = azurerm_network_interface.jumpbox.id
  network_security_group_id = azurerm_network_security_group.jumpbox.id
}

locals {
  jumpbox_env = <<-EOT
    export SUBSCRIPTION_ID="${var.subscription_id}"
    export TENANT_ID="${data.azurerm_client_config.current.tenant_id}"
    export LOCATION="${var.location}"
    export RESOURCE_GROUP="${azurerm_resource_group.this.name}"
    export HUB_VNET_ID="${azurerm_virtual_network.hub.id}"
    export ROUTE_TABLE_ID="${try(azurerm_route_table.nodes[0].id, "")}"
    export AKS_MODULE_VERSION="${var.aks_module_version}"
    export EXAMPLE_DIR="/home/azureuser/aks-avm/examples/finos-ccc"
    export APP_DNS_ZONE_NAME="${azurerm_private_dns_zone.apps.name}"
    export TRADERX_INSTANCES="${var.traderx_instances}"
    # Sources allowed to reach the TraderX load balancers: you and the jumpbox.
    export LB_ALLOWED_CIDRS="${var.admin_ssh_source_cidr},${azurerm_public_ip.jumpbox.ip_address}/32"
  EOT

  jumpbox_files = {
    "/opt/aks-ccc/env.sh"                        = { content = local.jumpbox_env, mode = "0644" }
    "/opt/aks-ccc/terraform.tfvars.json"         = { content = local.example_tfvars_json, mode = "0644" }
    "/opt/aks-ccc/bootstrap.sh"                  = { content = file("${path.module}/jumpbox-bootstrap.sh"), mode = "0755" }
    "/opt/aks-ccc/10-run-example.sh"             = { content = file("${path.module}/../scripts/10-run-example.sh"), mode = "0755" }
    "/opt/aks-ccc/15-install-cluster-addons.sh"  = { content = file("${path.module}/../scripts/15-install-cluster-addons.sh"), mode = "0755" }
    "/opt/aks-ccc/20-verify-cluster.sh"          = { content = file("${path.module}/../scripts/20-verify-cluster.sh"), mode = "0755" }
    "/opt/aks-ccc/30-deploy-traderx.sh"          = { content = file("${path.module}/../scripts/30-deploy-traderx.sh"), mode = "0755" }
    "/opt/aks-ccc/40-setup-ccc-tests.sh"         = { content = file("${path.module}/../scripts/40-setup-ccc-tests.sh"), mode = "0755" }
    "/opt/aks-ccc/50-run-ccc-tests.sh"           = { content = file("${path.module}/../scripts/50-run-ccc-tests.sh"), mode = "0755" }
    "/opt/aks-ccc/90-destroy-example.sh"         = { content = file("${path.module}/../scripts/90-destroy-example.sh"), mode = "0755" }
    "/opt/aks-ccc/95-destroy-ccc-tests.sh"       = { content = file("${path.module}/../scripts/95-destroy-ccc-tests.sh"), mode = "0755" }
    "/opt/aks-ccc/ccc-privateer-config.yml.tmpl" = { content = file("${path.module}/../ccc-tests/privateer-config.yml.tmpl"), mode = "0644" }
    "/opt/aks-ccc/ccc-k8s-fixtures.yaml"         = { content = file("${path.module}/../ccc-tests/k8s-fixtures.yaml"), mode = "0644" }
    "/opt/aks-ccc/ccc-webhook-probe.yaml"        = { content = file("${path.module}/../ccc-tests/webhook-probe.yaml"), mode = "0644" }
    "/opt/aks-ccc/ccc-dashboard.py"              = { content = file("${path.module}/../ccc-tests/dashboard.py"), mode = "0755" }
    "/opt/aks-ccc/workshop_variables.tf"         = { content = file("${path.module}/../example/workshop_variables.tf"), mode = "0644" }
    "/opt/aks-ccc/workshop_override.tf"          = { content = file("${path.module}/../example/workshop_override.tf"), mode = "0644" }
    "/opt/aks-ccc/workshop_external_dns.tf"      = { content = file("${path.module}/../example/workshop_external_dns.tf"), mode = "0644" }
    "/opt/aks-ccc/traderx.yaml"                  = { content = file(pathexpand(coalesce(var.traderx_manifest_path, "${path.module}/../../../examples/traderx/traderx-aks-demo.yaml"))), mode = "0644" }
  }

  # Azure limits custom data to 87,380 base64 characters (64 KB). The whole
  # cloud-config is gzipped once (cloud-init decompresses gzip user data), which
  # compresses far better than gzipping and base64-encoding each file.
  cloud_init = "#cloud-config\n${yamlencode({
    write_files = [for path, f in local.jumpbox_files : {
      path        = path
      permissions = f.mode
      content     = f.content
    }]
    runcmd = [["bash", "-c", "/opt/aks-ccc/bootstrap.sh > /var/log/aks-ccc-bootstrap.log 2>&1"]]
  })}"
  custom_data = base64gzip(local.cloud_init)
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                            = "vm-${local.name}-jumpbox"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = var.location
  size                            = var.jumpbox_vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.jumpbox.id]
  custom_data                     = local.custom_data
  tags                            = var.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # cloud-init only runs on first boot, and replacing the VM would lose the
  # example's Terraform state on it. Push later changes with
  # scripts/05-sync-jumpbox.sh instead.
  lifecycle {
    ignore_changes = [custom_data]

    precondition {
      condition     = length(local.custom_data) <= 87380
      error_message = "The jumpbox files are too large for Azure custom data (${length(local.custom_data)} of 87380 base64 characters). Shrink the TraderX manifest (traderx_manifest_path) or the scripts."
    }
  }
}

# The same files as cloud-init, for scripts/05-sync-jumpbox.sh.
resource "local_file" "jumpbox_files" {
  for_each = local.jumpbox_files

  filename        = "${path.module}/generated/jumpbox/${basename(each.key)}"
  content         = each.value.content
  file_permission = each.value.mode
}
