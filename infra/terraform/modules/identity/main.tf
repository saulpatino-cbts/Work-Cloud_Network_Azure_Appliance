data "azurerm_client_config" "current" {}

resource "azurerm_user_assigned_identity" "this" {
  name                = local.managed_identity_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}


resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV2_AZURE_32:Private endpoint is created in the security module and wired to this vault through its resource ID.
  #checkov:skip=CKV_AZURE_189:public_network_access stays enabled so the GitHub-hosted deploy runner can write secrets through a temporary, deny-by-default firewall window (210, 340 and the drift workflows add/remove the runner IP). Literal public-access-disabled (PE-only) requires a VNet-joined runner — tracked separately. See docs/adr/0004.
  name                          = local.key_vault_name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  rbac_authorization_enabled    = true
  public_network_access_enabled = true

  # Deny-by-default firewall. Data-plane access is over the private endpoint
  # (apps, via managed identity) plus a temporary runner-IP allow-rule that the
  # 210 deploy, 340 sync-keys and the 350/360 drift workflows add before they
  # touch secrets and remove afterwards. AzureServices bypass covers the Front Door
  # certificate path.
  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = var.bootstrap_ip_rules
  }

  # The transient runner IP is added/removed imperatively by the workflows; it
  # must not fight Terraform (ephemeral, would otherwise show as perpetual drift).
  # default_action / bypass stay Terraform-managed and drift-detected.
  lifecycle {
    ignore_changes = [network_acls[0].ip_rules]
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "terraform_key_vault_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grants for the app's own user-assigned managed identity. These live here
# (not in the security module) because they depend only on this module's own
# resources — keeping them in security would force module.compute to depend on
# module.security for RBAC while module.security already depends on
# module.compute for Container App IDs, a circular dependency. Placing them in
# identity lets every downstream module (compute, security, runtime) safely
# depend on identity's RBAC-gated outputs without any cycle.
resource "azurerm_role_assignment" "managed_identity_key_vault_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "time_sleep" "wait_for_rbac_propagation" {
  depends_on = [
    azurerm_role_assignment.terraform_key_vault_officer,
    azurerm_role_assignment.managed_identity_key_vault_secrets_user,
  ]

  create_duration = "60s"
}
