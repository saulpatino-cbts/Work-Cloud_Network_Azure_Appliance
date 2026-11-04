mock_provider "azurerm" {
  mock_data "azurerm_network_watcher" {
    defaults = {
      id = "/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_westeurope"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-4111-8111-111111111111"
      subscription_id = "22222222-2222-4222-8222-222222222222"
      client_id       = "33333333-3333-4333-8333-333333333333"
      object_id       = "44444444-4444-4444-8444-444444444444"
    }
  }
}
mock_provider "azapi" {}
mock_provider "time" {}

variables {
  tenant_id          = "11111111-1111-4111-8111-111111111111"
  location           = "westeurope"
  region_short       = "weu"
  fixture_value      = "synthetic-test-only"
  fixture_expiration = "2030-01-01T00:00:00Z"
  fixture_hash       = "pbkdf2$sha256$210000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  fixture_name       = "cna-local-admin-password"
}

run "saas_closes_public_byo_egress" {
  command = plan
  variables {
    ai_mode          = "saas"
    byo_ai_providers = ["anthropic", "openai"]
  }
  assert {
    condition     = length(local.byo_ai_provider_fqdns) == 0
    error_message = "saas must not open public BYO provider endpoints."
  }
}

run "openai_only_uses_exact_host_and_https" {
  command = plan
  variables {
    ai_mode          = "byo-api"
    byo_ai_providers = ["openai"]
  }
  assert {
    condition     = join(",", local.byo_ai_provider_fqdns) == "api.openai.com"
    error_message = "Selecting OpenAI must not also allow Anthropic or a wildcard."
  }
  assert {
    condition = length([
      for collection in azurerm_firewall_policy_rule_collection_group.egress.application_rule_collection :
      collection if collection.name == "allow-approved-byo-ai"
      ]) == 1 && alltrue([
      for collection in azurerm_firewall_policy_rule_collection_group.egress.application_rule_collection :
      alltrue([for rule in collection.rule : alltrue([for protocol in rule.protocols : protocol.type == "Https" && protocol.port == 443])])
      if collection.name == "allow-approved-byo-ai"
    ])
    error_message = "Approved BYO egress must have a dedicated HTTPS-only collection."
  }
  assert {
    condition     = !contains(local.firewall_application_rule_fqdns, "api.openai.com")
    error_message = "BYO must never inherit the baseline HTTP rule."
  }
}

run "both_approved_providers" {
  command = plan
  variables {
    ai_mode          = "byo-api"
    byo_ai_providers = ["openai", "anthropic"]
  }
  assert {
    condition     = join(",", local.byo_ai_provider_fqdns) == "api.anthropic.com,api.openai.com"
    error_message = "Both approved providers must map to exact deterministic FQDNs."
  }
}

run "byo_without_approval_is_rejected" {
  command = plan
  variables {
    ai_mode          = "byo-api"
    byo_ai_providers = []
  }
  expect_failures = [var.byo_ai_providers]
}

run "placeholder_tenant_is_rejected" {
  command = plan
  variables {
    tenant_id = "00000000-0000-0000-0000-000000000000"
  }
  expect_failures = [var.tenant_id]
}

run "break_glass_hash_is_optional" {
  command = plan
  module {
    source = "../../../modules/runtime"
  }
  variables {
    resource_group_name           = "rg-cna-dev-weu"
    storage_account_id            = "/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-cna-dev-weu/providers/Microsoft.Storage/storageAccounts/clientteststorage"
    key_vault_id                  = "/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-cna-dev-weu/providers/Microsoft.KeyVault/vaults/clienttestvault"
    managed_identity_principal_id = "44444444-4444-4444-8444-444444444444"
    database_url                  = var.fixture_value
    nextauth_secret               = var.fixture_value
    entra_client_secret           = var.fixture_value
    credential_encryption_key     = var.fixture_value
    api_token                     = var.fixture_value
    secret_expiration_date        = var.fixture_expiration
  }
  assert {
    condition     = length(azurerm_key_vault_secret.local_admin_password) == 0 && output.local_admin_password_secret_name == null
    error_message = "An unset hash must provision no break-glass secret."
  }
}

run "sensitive_break_glass_hash_can_be_configured" {
  command = plan
  module {
    source = "../../../modules/runtime"
  }

  variables {
    resource_group_name           = "rg-cna-dev-weu"
    storage_account_id            = "/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-cna-dev-weu/providers/Microsoft.Storage/storageAccounts/clientteststorage"
    key_vault_id                  = "/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-cna-dev-weu/providers/Microsoft.KeyVault/vaults/clienttestvault"
    managed_identity_principal_id = "44444444-4444-4444-8444-444444444444"
    database_url                  = var.fixture_value
    nextauth_secret               = var.fixture_value
    entra_client_secret           = var.fixture_value
    credential_encryption_key     = var.fixture_value
    api_token                     = var.fixture_value
    secret_expiration_date        = var.fixture_expiration
    local_admin_password          = var.fixture_hash
  }
  assert {
    condition     = length(azurerm_key_vault_secret.local_admin_password) == 1 && output.local_admin_password_secret_name == var.fixture_name
    error_message = "A configured sensitive hash must plan without leaking its value or producing a sensitive count."
  }
}

run "runtime_reads_while_deployer_writes_secrets" {
  command = plan
  module {
    source = "../../../modules/identity"
  }
  variables {
    resource_group_name = "rg-cna-dev-weu"
    location            = "westeurope"
    name_prefix         = "cna-dev-weu"
    tenant_id           = "11111111-1111-4111-8111-111111111111"
    bootstrap_ip_rules  = ["192.0.2.10"]
  }
  assert {
    condition     = azurerm_role_assignment.managed_identity_key_vault_secrets_user.role_definition_name == "Key Vault Secrets User" && azurerm_role_assignment.terraform_key_vault_officer.principal_id == "44444444-4444-4444-8444-444444444444"
    error_message = "Runtime must use the read-only secret role; the deploy principal owns secret writing."
  }
  assert {
    condition     = azurerm_key_vault.this.network_acls[0].default_action == "Deny" && contains(azurerm_key_vault.this.network_acls[0].ip_rules, "192.0.2.10")
    error_message = "New vaults need the tracked bootstrap runner rule while retaining default-deny."
  }
}
