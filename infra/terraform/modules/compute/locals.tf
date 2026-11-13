locals {
  container_apps_env_name = "${var.name_prefix}-cae"

  # Identity type for all Container Apps. When a user-assigned identity is provided
  # (for Key Vault secret references), we combine it with the system-assigned identity
  # so that existing RBAC assignments on the system identity continue to work.
  identity_type = var.key_vault_reference_identity_id != null ? "SystemAssigned, UserAssigned" : "SystemAssigned"
  uai_ids       = var.key_vault_reference_identity_id != null ? [var.key_vault_reference_identity_id] : []

  # KV reference secrets flattened to a list for use in dynamic blocks.
  kv_secrets_list = [
    for name, uri in var.container_app_kv_secrets : { name = name, uri = uri }
  ]
  container_apps_infra_resource_group_name = coalesce(
    var.container_app_environment_infrastructure_resource_group_name,
    "rg-${var.name_prefix}-cae-managed"
  )
  api_app_name = "${var.name_prefix}-ca-api"
  web_app_name = "${var.name_prefix}-ca-web"

  # Private non-ACR registries such as Docker Hub use username + token auth.
  # If credentials are omitted, the registry block falls back to managed identity for ACR.
  use_registry_credentials = nonsensitive(var.container_registry_username != "" && var.container_registry_password != "")

  api_plain_env_vars = [
    for name, value in var.api_env_vars : {
      name  = name
      value = value
    }
  ]

  web_plain_env_vars = [
    for name, value in var.web_env_vars : {
      name  = name
      value = value
    }
  ]

  api_secret_env_vars = [
    for name, secret_name in var.api_secret_env_vars : {
      name        = name
      secret_name = secret_name
    }
  ]

  web_secret_env_vars = [
    for name, secret_name in var.web_secret_env_vars : {
      name        = name
      secret_name = secret_name
    }
  ]
}
