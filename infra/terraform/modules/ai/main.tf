resource "azurerm_cognitive_account" "foundry" {
  name                          = var.foundry_account_name
  location                      = var.foundry_location
  resource_group_name           = var.resource_group_name
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = var.foundry_account_name
  project_management_enabled    = true
  local_auth_enabled            = false
  public_network_access_enabled = false

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, local.foundry_tags)
}

# The project is a child resource of the Cognitive Services account. Terraform's
# implicit dependency via parent_id only waits for the account's create call to
# return, not for it to reach a terminal provisioning state — the same
# "RequestConflict: provisioning state is not terminal" race already handled
# for private endpoints in the security module (time_sleep.private_endpoint_settle).
resource "time_sleep" "foundry_account_settle" {
  create_duration = "30s"

  triggers = {
    foundry_account_id = azurerm_cognitive_account.foundry.id
  }
}

# Chat model deployment. The app resolves models by DEPLOYMENT name
# (AZURE_OPENAI_DEPLOYMENT=gpt-chat-latest), so the stable alias lives here and
# the underlying model/version is pinned via variables. Previously this
# deployment only existed portal-created on the old cna-dev-eus2-aif account and
# was lost when the account name was bumped to -aif2 — declaring it in Terraform
# makes it survive teardown/redeploy.
resource "azurerm_cognitive_deployment" "chat" {
  count = var.chat_deployment_enabled ? 1 : 0

  cognitive_account_id = azurerm_cognitive_account.foundry.id
  name                 = var.chat_deployment_name

  model {
    format  = "OpenAI"
    name    = var.chat_model_name
    version = var.chat_model_version
  }

  sku {
    name     = var.chat_deployment_sku_name
    capacity = var.chat_deployment_capacity
  }

  depends_on = [time_sleep.foundry_account_settle]
}

resource "azapi_resource" "foundry_project" {
  lifecycle {
    prevent_destroy = true
  }

  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = var.foundry_project_name
  parent_id = azurerm_cognitive_account.foundry.id
  location  = var.foundry_location

  depends_on = [time_sleep.foundry_account_settle]

  body = {
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      displayName = var.foundry_project_name
      description = "CNA ${var.environment} Foundry project hosting the Azure OpenAI deployment"
    }
  }

  tags = merge(var.tags, local.foundry_tags)
}
