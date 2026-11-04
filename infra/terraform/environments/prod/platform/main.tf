# Workload resource group — created by workflow 000 and immediately imported
# into Terraform state so 031 / 032 continue to own the full app stack RG.
resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "platform" {
  name                = "${local.name_prefix}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "container_apps_infra" {
  name                 = "${local.name_prefix}-snet-aca"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.platform.name
  address_prefixes     = var.subnet_container_apps_infra_prefixes

  delegation {
    name = "container-apps-delegation"

    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "${local.name_prefix}-snet-pe"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.platform.name
  address_prefixes                  = var.subnet_private_endpoints_prefixes
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.platform.name
  address_prefixes     = var.subnet_firewall_prefixes
}

# PostgreSQL Flexible Server requires a dedicated delegated subnet — it does NOT
# use a private endpoint. The subnet must be delegated to
# Microsoft.DBforPostgreSQL/flexibleServers and cannot contain other resources.
resource "azurerm_subnet" "database" {
  name                 = "${local.name_prefix}-snet-db"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.platform.name
  address_prefixes     = var.subnet_database_prefixes

  delegation {
    name = "postgres-flexible-delegation"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}


resource "azurerm_network_security_group" "container_apps" {
  name                = "${local.name_prefix}-nsg-aca"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "container_apps_to_private_endpoints_https" {
  name                        = "allow-aca-to-pe-443"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = azurerm_subnet.container_apps_infra.address_prefixes[0]
  destination_address_prefix  = azurerm_subnet.private_endpoints.address_prefixes[0]
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.container_apps.name
}

resource "azurerm_network_security_rule" "container_apps_to_database_postgres" {
  name                        = "allow-aca-to-db-5432"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5432"
  source_address_prefix       = azurerm_subnet.container_apps_infra.address_prefixes[0]
  destination_address_prefix  = azurerm_subnet.database.address_prefixes[0]
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.container_apps.name
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "${local.name_prefix}-nsg-pe"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "private_endpoints_from_container_apps_https" {
  name                        = "allow-aca-to-pe-443"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = azurerm_subnet.container_apps_infra.address_prefixes[0]
  destination_address_prefix  = azurerm_subnet.private_endpoints.address_prefixes[0]
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_rule" "private_endpoints_deny_other_vnet_inbound" {
  name                        = "deny-other-vnet-inbound"
  priority                    = 400
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_group" "database" {
  name                = "${local.name_prefix}-nsg-db"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "database_from_container_apps_postgres" {
  name                        = "allow-aca-to-db-5432"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5432"
  source_address_prefix       = azurerm_subnet.container_apps_infra.address_prefixes[0]
  destination_address_prefix  = azurerm_subnet.database.address_prefixes[0]
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.database.name
}

resource "azurerm_network_security_rule" "database_deny_other_vnet_inbound" {
  name                        = "deny-other-vnet-inbound"
  priority                    = 400
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.database.name
}

resource "azurerm_public_ip" "firewall" {
  name                = "${local.name_prefix}-pip-afw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags
}

resource "azurerm_firewall_policy" "egress" {
  name                = "${local.name_prefix}-afwp"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Premium"
  tags                = local.tags
}

resource "azurerm_firewall" "egress" {
  name                = "${local.name_prefix}-afw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Premium"
  firewall_policy_id  = azurerm_firewall_policy.egress.id
  tags                = local.tags

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "${local.name_prefix}-afw-rcg"
  firewall_policy_id = azurerm_firewall_policy.egress.id
  priority           = 100

  network_rule_collection {
    name     = "allow-platform-dns"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "allow-azure-dns"
      protocols             = ["TCP", "UDP"]
      source_addresses      = [azurerm_subnet.container_apps_infra.address_prefixes[0]]
      destination_addresses = ["168.63.129.16"]
      destination_ports     = ["53"]
    }
  }

  dynamic "application_rule_collection" {
    for_each = length(local.byo_ai_provider_fqdns) > 0 ? [local.byo_ai_provider_fqdns] : []
    content {
      name     = "allow-approved-byo-ai"
      priority = 210
      action   = "Allow"
      rule {
        name              = "allow-approved-byo-ai-https"
        source_addresses  = [azurerm_subnet.container_apps_infra.address_prefixes[0]]
        destination_fqdns = application_rule_collection.value
        protocols {
          type = "Https"
          port = 443
        }
      }
    }
  }

  application_rule_collection {
    name     = "allow-web-outbound-baseline"
    priority = 200
    action   = "Allow"

    rule {
      name              = "allow-baseline-web-egress"
      source_addresses  = [azurerm_subnet.container_apps_infra.address_prefixes[0]]
      destination_fqdns = local.firewall_application_rule_fqdns

      protocols {
        type = "Http"
        port = 80
      }

      protocols {
        type = "Https"
        port = 443
      }
    }
  }
}

resource "azurerm_route_table" "container_apps_egress" {
  name                = "${local.name_prefix}-rt-aca-egress"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_route" "container_apps_default_to_firewall" {
  name                   = "default-to-firewall"
  resource_group_name    = azurerm_resource_group.this.name
  route_table_name       = azurerm_route_table.container_apps_egress.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.egress.ip_configuration[0].private_ip_address
}

resource "azurerm_subnet_network_security_group_association" "container_apps_infra" {
  subnet_id                 = azurerm_subnet.container_apps_infra.id
  network_security_group_id = azurerm_network_security_group.container_apps.id
}

resource "azurerm_subnet_route_table_association" "container_apps_egress" {
  subnet_id      = azurerm_subnet.container_apps_infra.id
  route_table_id = azurerm_route_table.container_apps_egress.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

resource "azurerm_subnet_network_security_group_association" "database" {
  subnet_id                 = azurerm_subnet.database.id
  network_security_group_id = azurerm_network_security_group.database.id
}

resource "azurerm_network_security_rule" "container_apps_allow_internal" {
  name                        = "allow-aca-internal"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = azurerm_subnet.container_apps_infra.address_prefixes[0]
  destination_address_prefix  = azurerm_subnet.container_apps_infra.address_prefixes[0]
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.container_apps.name
}

resource "azurerm_network_security_rule" "container_apps_deny_other_vnet_inbound" {
  name                        = "deny-other-vnet-inbound"
  priority                    = 400
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.container_apps.name
}

# ─── Platform observability ───────────────────────────────────────────────────
# The Log Analytics workspace lives in the platform landing zone so that
# platform-owned resources (firewall, NSGs, VNet flow logs) are monitored in the
# same state that creates them — no cross-state dependency. The workload reads
# this workspace via data source for its Container App / app diagnostics.
resource "azurerm_log_analytics_workspace" "platform" {
  name                = "${local.name_prefix}-log"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = local.log_analytics_retention_in_days
  tags                = local.tags
}

# Dedicated storage account for VNet flow logs. LRS is appropriate (and the
# Network Watcher flow-log requirement is exempt from the GZRS curated gate);
# logs are short-lived diagnostic data, not durable artifacts. Security posture
# mirrors the application storage account so the curated Checkov gate passes.
resource "azurerm_storage_account" "flow_logs" {
  #checkov:skip=CKV_AZURE_206:Flow-log storage is short-lived diagnostic data; LRS is acceptable and Network Watcher does not require geo-replication.
  #checkov:skip=CKV2_AZURE_1:Customer-managed key support is deferred until Key Vault key lifecycle is validated.
  #checkov:skip=CKV2_AZURE_33:Flow-log storage is reached over the platform VNet; a private endpoint is not warranted for diagnostic data.
  #checkov:skip=CKV_AZURE_59:Network Watcher writes flow logs over the data plane; public network access cannot be disabled outright for this account.
  #checkov:skip=CKV2_AZURE_40:Network Watcher uses Shared Key authorization to write flow logs.
  name                            = replace("${local.name_prefix}flowlog", "-", "")
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  shared_access_key_enabled       = true
  tags                            = local.tags

  sas_policy {
    expiration_period = "1.00:00:00"
    expiration_action = "Log"
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  # Public network access can't be disabled outright (Network Watcher writes
  # flow logs over the data plane), but it shouldn't be open to every source
  # IP either. AzureServices bypass keeps Network Watcher's writes working
  # while Deny blocks arbitrary internet access to the account.
  network_rules {
    bypass         = ["AzureServices"]
    default_action = "Deny"
  }
}

module "observability" {
  source                               = "../../../modules/observability"
  log_analytics_workspace_id           = azurerm_log_analytics_workspace.platform.id
  log_analytics_workspace_workspace_id = azurerm_log_analytics_workspace.platform.workspace_id
  log_analytics_workspace_location     = azurerm_log_analytics_workspace.platform.location
  diagnostic_setting_name_prefix       = local.name_prefix
  resource_group_name                  = azurerm_resource_group.this.name
  location                             = azurerm_resource_group.this.location
  tags                                 = local.tags

  # VNet flow logs — platform owns the storage account and the VNet.
  enable_virtual_network_flow_logs = true
  flow_log_target_resource_id      = azurerm_virtual_network.platform.id
  flow_log_storage_account_id      = azurerm_storage_account.flow_logs.id

  # Firewall + NSG diagnostics (the resources that moved here in the split).
  diagnostic_targets = {
    azure_firewall        = azurerm_firewall.egress.id
    container_apps_nsg    = azurerm_network_security_group.container_apps.id
    private_endpoints_nsg = azurerm_network_security_group.private_endpoints.id
    database_nsg          = azurerm_network_security_group.database.id
  }

  # Stand down when an ALZ DeployIfNotExists policy already governs diagnostics
  # (the policy-gates pre-flight sets this false via TF_VAR_manage_diagnostic_settings).
  manage_diagnostic_settings = var.manage_diagnostic_settings
}
