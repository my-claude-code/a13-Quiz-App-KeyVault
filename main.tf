terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  prefix         = "quiz-app"
  app_private_ip = "10.0.1.10"
}

# ── Current Azure context (subscription + object ID of deployer) ─────────────
data "azurerm_client_config" "current" {}

# ── Key Vault (existing) ──────────────────────────────────────────────────────
data "azurerm_key_vault" "kv" {
  name                = "vault-test-subscription"
  resource_group_name = "Vault_RG"
}

# ── Secrets pulled from Key Vault ─────────────────────────────────────────────
data "azurerm_key_vault_secret" "entra_tenant_id" {
  name         = "quiz-entra-tenant-id"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "entra_client_id" {
  name         = "quiz-entra-client-id"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "entra_client_secret" {
  name         = "quiz-entra-client-secret"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "admin_username" {
  name         = "quiz-admin-username"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "admin_password" {
  name         = "quiz-admin-password"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "flask_secret_key" {
  name         = "quiz-flask-secret-key"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "db_password" {
  name         = "quiz-db-password"
  key_vault_id = data.azurerm_key_vault.kv.id
}

# ── Resource Group ────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.prefix}"
  location = var.location
}

# ── Virtual Network ───────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "app" {
  name                 = "subnet-app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "postgres" {
  name                 = "subnet-postgres"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ── NSG ───────────────────────────────────────────────────────────────────────
resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-${local.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "app" {
  network_interface_id      = azurerm_network_interface.app.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# ── Public IP ─────────────────────────────────────────────────────────────────
resource "azurerm_public_ip" "app" {
  name                = "pip-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ── NIC ───────────────────────────────────────────────────────────────────────
resource "azurerm_network_interface" "app" {
  name                = "nic-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig-app"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.app_private_ip
    public_ip_address_id          = azurerm_public_ip.app.id
  }
}

# ── Private DNS Zone for PostgreSQL ──────────────────────────────────────────
resource "azurerm_private_dns_zone" "postgres" {
  name                = "quizapp.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.rg.name
  registration_enabled  = false

  depends_on = [
    azurerm_virtual_network.vnet,
    azurerm_subnet.app,
    azurerm_subnet.postgres,
  ]
}

# ── PostgreSQL Flexible Server ────────────────────────────────────────────────
resource "azurerm_postgresql_flexible_server" "db" {
  name                          = "psql-quiz-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  version                       = "16"
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  administrator_login           = "quizadmin"
  administrator_password        = data.azurerm_key_vault_secret.db_password.value
  storage_mb                    = 32768
  sku_name                      = "B_Standard_B1ms"
  public_network_access_enabled = false

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "quiz" {
  name      = "quiz"
  server_id = azurerm_postgresql_flexible_server.db.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# ── App VM with system-assigned managed identity ──────────────────────────────
resource "azurerm_linux_virtual_machine" "app" {
  name                            = "vm-app"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = data.azurerm_key_vault_secret.admin_username.value
  admin_password                  = data.azurerm_key_vault_secret.admin_password.value
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.app.id]

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(templatefile("${path.module}/scripts/app-setup.sh", {
    entra_client_id     = data.azurerm_key_vault_secret.entra_client_id.value
    entra_client_secret = data.azurerm_key_vault_secret.entra_client_secret.value
    entra_tenant_id     = data.azurerm_key_vault_secret.entra_tenant_id.value
    flask_secret_key    = data.azurerm_key_vault_secret.flask_secret_key.value
    app_public_ip       = azurerm_public_ip.app.ip_address
    pg_host             = azurerm_postgresql_flexible_server.db.fqdn
    db_password         = data.azurerm_key_vault_secret.db_password.value
    github_repo         = var.github_repo
    kv_name             = data.azurerm_key_vault.kv.name
    domain              = var.domain
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  depends_on = [azurerm_postgresql_flexible_server_database.quiz]
}

# ── Grant VM managed identity access to Key Vault ────────────────────────────
resource "azurerm_role_assignment" "vm_kv_secrets" {
  scope                = data.azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
}
