data "azurerm_resource_group" "this" {
  name = "rg-${local.name_prefix}"
}

data "azurerm_virtual_network" "platform" {
  name                = "${local.name_prefix}-vnet"
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_subnet" "container_apps_infra" {
  name                 = "${local.name_prefix}-snet-aca"
  virtual_network_name = data.azurerm_virtual_network.platform.name
  resource_group_name  = data.azurerm_resource_group.this.name
}

data "azurerm_subnet" "private_endpoints" {
  name                 = "${local.name_prefix}-snet-pe"
  virtual_network_name = data.azurerm_virtual_network.platform.name
  resource_group_name  = data.azurerm_resource_group.this.name
}

data "azurerm_subnet" "database" {
  name                 = "${local.name_prefix}-snet-db"
  virtual_network_name = data.azurerm_virtual_network.platform.name
  resource_group_name  = data.azurerm_resource_group.this.name
}

# Log Analytics workspace lives in the platform landing zone (created there so
# firewall/NSG/flow-log diagnostics stay in the same state as their resources).
# The workload reads it for Container App + app-level diagnostics.
data "azurerm_log_analytics_workspace" "platform" {
  name                = "${local.name_prefix}-log"
  resource_group_name = data.azurerm_resource_group.this.name
}

module "storage" {
  source              = "../../../modules/storage"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  name_prefix         = local.name_prefix
  tags                = merge(local.tags, var.deploy_runner_ip != "" ? { CnaRunnerIp = var.deploy_runner_ip } : {})

  # GZRS satisfies the curated Checkov geo-replication gate (CKV_AZURE_206).
  replication_type            = "GZRS"
  raw_artifact_retention_days = 30 # move to Cool after 30 days, auto-delete after 365
  deliverable_retention_days  = 90

  # First-apply only (ignore_changes afterwards): the deploy runner's public IP,
  # so the static website can be provisioned over the data plane in the same
  # apply that creates the deny-by-default account. Set by 210-deploy.
  bootstrap_ip_rules = var.deploy_runner_ip != "" ? [var.deploy_runner_ip] : []
}

module "identity" {
  source              = "../../../modules/identity"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  name_prefix         = local.name_prefix
  tenant_id           = var.tenant_id
  tags                = merge(local.tags, var.deploy_runner_ip != "" ? { CnaRunnerIp = var.deploy_runner_ip } : {})
  bootstrap_ip_rules  = var.deploy_runner_ip != "" ? [var.deploy_runner_ip] : []

  # Tenant policy requires purge protection on all Key Vaults (new and prod).
  # 90-day retention is paired with purge protection per Azure best practice.
  # NOTE: once purge protection is on, vault name is reserved for 90 days after
  # deletion — increment key_vault_name_suffix on next full teardown.
  key_vault_soft_delete_retention_days = 90
  key_vault_purge_protection_enabled   = true
  key_vault_name_suffix                = "2"
}

module "compute" {
  source                               = "../../../modules/compute"
  resource_group_name                  = data.azurerm_resource_group.this.name
  location                             = data.azurerm_resource_group.this.location
  name_prefix                          = local.name_prefix
  api_image                            = var.api_image
  worker_image                         = var.worker_image
  web_image                            = var.web_image
  container_apps_internal_only         = false
  container_apps_public_network_access = "Disabled"
  container_app_environment_workload_profiles = [{
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }]
  infrastructure_subnet_id             = data.azurerm_subnet.container_apps_infra.id
  web_ingress_ip_security_restrictions = var.web_ingress_ip_security_restrictions
  container_registry_username          = var.container_registry_username
  container_registry_password          = var.container_registry_password
  tags                                 = local.tags

  # FinOps: do NOT scale to zero in prod — cold-start impacts SLA
  enable_scale_to_zero       = false
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.platform.id

  # ── Plain env vars injected at container start ──────────────────────────────
  # Foundry recommendation agent (portal-configured: MCP tools + instructions).
  # Empty values keep the agent transport off; RecommendationEngine then uses the
  # direct MCP clients and the offline library.
  # AZURE_OPENAI_* must reach the API and worker too, not just web: cna-api's
  # GroundedChatAgent raises ChatConfigError (→ 503 on /chat, all analysis
  # types fail) when AZURE_OPENAI_ENDPOINT is absent from its own environment.
  #
  # AZURE_CLIENT_ID: all three container apps carry BOTH a system-assigned and
  # the shared user-assigned identity (key_vault_reference_identity_id above).
  # DefaultAzureCredential's ManagedIdentityCredential defaults to "system-
  # assigned" only when unambiguous; with two identities attached, Container
  # Apps' identity endpoint returns "(invalid_scope) 500" instead of resolving
  # the default. Setting AZURE_CLIENT_ID pins DefaultAzureCredential to the
  # user-assigned identity (which already holds Cognitive Services User on the
  # AI Foundry account) and removes the ambiguity. Diagnosed 2026-07-02 in dev;
  # applied here pre-emptively so prod doesn't hit it when AI is enabled.
  # AI env (local.azure_ai_env_vars, saas only) and the mode contract
  # (local.ai_mode_env_vars) are merged in from locals.tf so the two modes
  # differ only by those keys.
  api_env_vars = merge(
    {
      CNA_STORAGE_ACCOUNT_NAME = module.storage.storage_account_name
      AZURE_CLIENT_ID          = module.identity.managed_identity_client_id
    },
    local.azure_ai_env_vars,
    local.ai_mode_env_vars,
  )

  worker_env_vars = merge(
    {
      CNA_STORAGE_ACCOUNT_NAME = module.storage.storage_account_name
      AZURE_CLIENT_ID          = module.identity.managed_identity_client_id
    },
    local.azure_ai_env_vars,
    local.ai_mode_env_vars,
  )

  web_env_vars = merge(
    {
      NEXTAUTH_URL                        = var.nextauth_url
      AUTH_TRUST_HOST                     = "true"
      AZURE_AD_TENANT_ID                  = var.tenant_id
      AZURE_AD_CLIENT_ID                  = var.entra_client_id
      AZURE_CLIENT_ID                     = module.identity.managed_identity_client_id
      CNA_API_INTERNAL_URL                = "http://${local.name_prefix}-ca-api"
      AZURE_STORAGE_ACCOUNT_NAME          = module.storage.storage_account_name
      AZURE_STORAGE_CONTAINER_ENGAGEMENTS = "raw-artifacts"
      CNA_AZURE_MCP_ENDPOINT              = var.azure_mcp_endpoint
      CNA_AZURE_MCP_TRANSPORT             = var.azure_mcp_transport
      CNA_AWS_MCP_ENDPOINT                = var.aws_mcp_endpoint
      CNA_AWS_MCP_TRANSPORT               = var.aws_mcp_transport
      CNA_DRAWIO_MCP_URL                  = var.drawio_mcp_url
    },
    local.azure_ai_env_vars,
    local.ai_mode_env_vars,
    local.image_update_env_vars,
  )

  # ── Secret-backed env vars (reference Container App secrets by name) ─────────
  # LOCAL_ADMIN_PASSWORD is only added when the break-glass feature has been
  # bootstrapped for this environment (var.local_admin_password != null).
  web_secret_env_vars = merge(
    {
      DATABASE_URL              = "database-url"
      AUTH_SECRET               = "nextauth-secret" # Auth.js v5 canonical name (was NEXTAUTH_SECRET)
      AZURE_AD_CLIENT_SECRET    = "entra-client-secret"
      CREDENTIAL_ENCRYPTION_KEY = "credential-encryption-key"
      CNA_API_TOKEN             = "api-token" # bearer token cna-web sends to cna-api
    },
    nonsensitive(var.local_admin_password != null) ? { LOCAL_ADMIN_PASSWORD = "local-admin-password" } : {},
    # Same Container App secret the registry block pulls with (compute module).
    local.use_registry_credentials ? { CNA_IMAGE_REGISTRY_TOKEN = "container-registry-password" } : {},
  )

  # cna-api needs DATABASE_URL to read/write discovery jobs and findings. In
  # byo-api mode it also decrypts the admin-entered AI keys from AppSetting, so
  # it needs the same encryption key the web tier uses (secret already exists).
  api_secret_env_vars = merge(
    {
      DATABASE_URL = "database-url"
      # cna-api requires this bearer token on every request except /health and
      # /ready (SEC-001/ARCH-002). cna-web presents the same token.
      CNA_API_TOKEN = "api-token"
    },
    local.ai_saas ? {} : { CREDENTIAL_ENCRYPTION_KEY = "credential-encryption-key" },
  )

  # ── Key Vault secret references ──────────────────────────────────────────────
  # Versionless URIs — Azure auto-refreshes the injected value within 30 minutes
  # when a new KV secret version is created (rotation, credential change, etc.).
  # The user-assigned managed identity (key_vault_reference_identity_id) must have
  # Key Vault Secrets User on the vault; Key Vault Secrets Officer covers this.
  container_app_kv_secrets = merge(
    {
      "database-url"              = "${module.identity.key_vault_uri}secrets/cna-database-url"
      "nextauth-secret"           = "${module.identity.key_vault_uri}secrets/cna-nextauth-secret"
      "entra-client-secret"       = "${module.identity.key_vault_uri}secrets/cna-entra-client-secret"
      "credential-encryption-key" = "${module.identity.key_vault_uri}secrets/cna-credential-encryption-key"
      "api-token"                 = "${module.identity.key_vault_uri}secrets/cna-api-token"
    },
    nonsensitive(var.local_admin_password != null) ? { "local-admin-password" = "${module.identity.key_vault_uri}secrets/cna-local-admin-password" } : {}
  )
  key_vault_reference_identity_id = module.identity.managed_identity_id

  # depends_on ensures KV secrets (created by module.runtime) exist before
  # Container Apps reference them. Without this, a fresh deploy would race.
  depends_on = [module.runtime]
}

# Only in saas mode. byo-api provisions no cloud AI resources at all; the app
# talks to Anthropic/OpenAI with admin-entered keys instead.
module "ai" {
  count               = local.ai_saas ? 1 : 0
  source              = "../../../modules/ai"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  name_prefix         = local.name_prefix
  tags                = local.tags

  environment          = var.environment
  foundry_location     = var.foundry_location
  foundry_account_name = local.foundry_account_name
  foundry_project_name = local.foundry_project_name
}

# Adding count re-addresses every resource in the module (module.ai ->
# module.ai[0]). Without these moved blocks the plan destroys and — with
# purge_soft_delete_on_destroy — PURGES the Foundry account and its chat
# deployment, then recreates them. Safe to delete once every environment has
# applied on this version.
moved {
  from = module.ai
  to   = module.ai[0]
}

moved {
  from = azurerm_role_assignment.web_foundry_user
  to   = azurerm_role_assignment.web_foundry_user[0]
}

moved {
  from = azurerm_role_assignment.api_foundry_user
  to   = azurerm_role_assignment.api_foundry_user[0]
}

moved {
  from = azurerm_role_assignment.uai_foundry_user
  to   = azurerm_role_assignment.uai_foundry_user[0]
}

moved {
  from = azurerm_role_assignment.worker_foundry_user
  to   = azurerm_role_assignment.worker_foundry_user[0]
}


# Bearer token for the internal cna-api (SEC-001/ARCH-002). 48 chars, no special
# characters so it is safe in an HTTP Authorization header. Generated here,
# stored in Key Vault by module.runtime, and injected into BOTH the api and web
# containers as CNA_API_TOKEN. Never accepted via a tfvar or a workflow input.
resource "random_password" "api_token" {
  length  = 48
  special = false
}

module "runtime" {
  source                        = "../../../modules/runtime"
  resource_group_name           = data.azurerm_resource_group.this.name
  storage_account_id            = module.storage.storage_account_id
  key_vault_id                  = module.identity.key_vault_id
  managed_identity_principal_id = module.identity.managed_identity_principal_id
  database_url                  = module.database.connection_string
  nextauth_secret               = var.nextauth_secret
  entra_client_secret           = var.entra_client_secret
  credential_encryption_key     = var.credential_encryption_key
  api_token                     = random_password.api_token.result
  local_admin_password          = var.local_admin_password
  secret_expiration_date        = var.secret_expiration_date
}

# ─── Container App RBAC ───────────────────────────────────────────────────────
# Each Container App uses its system-assigned managed identity via
# DefaultAzureCredential. All required role assignments are declared here so
# Terraform owns the full identity surface — no manual az role assignment calls.

# Storage: web uploads deliverables; api + worker read/write raw artifacts.
# The user-assigned identity needs this too: AZURE_CLIENT_ID pins
# DefaultAzureCredential to it in all three apps, so blob calls authenticate
# as the UAI, not the system-assigned identities. Without this grant, report
# generation succeeds but the final blob upload 403s. Diagnosed 2026-07-02 in dev.
resource "azurerm_role_assignment" "uai_storage_blob_data_contributor" {
  scope                = module.storage.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.identity.managed_identity_principal_id
}

resource "azurerm_role_assignment" "web_storage_blob_data_contributor" {
  scope                = module.storage.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.compute.web_principal_id
}

resource "azurerm_role_assignment" "api_storage_blob_data_contributor" {
  scope                = module.storage.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.compute.api_principal_id
}

resource "azurerm_role_assignment" "worker_storage_blob_data_contributor" {
  scope                = module.storage.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.compute.worker_principal_id
}

# Foundry RBAC exists only alongside the Foundry account (saas mode).
resource "azurerm_role_assignment" "web_foundry_user" {
  count                = local.ai_saas ? 1 : 0
  scope                = module.ai[0].foundry_account_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.compute.web_principal_id
}

resource "azurerm_role_assignment" "api_foundry_user" {
  count                = local.ai_saas ? 1 : 0
  scope                = module.ai[0].foundry_account_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.compute.api_principal_id
}

resource "azurerm_role_assignment" "uai_foundry_user" {
  count                = local.ai_saas ? 1 : 0
  scope                = module.ai[0].foundry_account_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.identity.managed_identity_principal_id
}

# Foundry Agent Service (data plane: threads/runs) for recommendation enrichment.
# Microsoft documents "Azure AI User" for the agents API, but that role does not
# exist in this tenant (`az role definition list --name "Azure AI User"` returns
# nothing), so assigning it fails the apply with "could not find role". In this
# tenant "Cognitive Services User" carries the Microsoft.CognitiveServices/*
# data actions — a superset that covers the agents API as well as inference —
# so it is the single Foundry role used here. web/api/UAI already hold it
# above; worker (agents only, no direct inference) gets it here.
resource "azurerm_role_assignment" "worker_foundry_user" {
  count                = local.ai_saas ? 1 : 0
  scope                = module.ai[0].foundry_account_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.compute.worker_principal_id
}


module "security" {
  frontdoor_custom_domain_host_name  = endswith(var.nextauth_url, ".azurefd.net") ? "" : trimprefix(var.nextauth_url, "https://")
  frontdoor_certificate_pfx_path     = var.frontdoor_certificate_pfx_path
  frontdoor_certificate_pfx_password = var.frontdoor_certificate_pfx_password
  source                             = "../../../modules/security"
  resource_group_name                = data.azurerm_resource_group.this.name
  location                           = data.azurerm_resource_group.this.location
  name_prefix                        = local.name_prefix
  key_vault_id                       = module.identity.key_vault_id
  key_vault_name                     = module.identity.key_vault_name
  api_container_app_id               = module.compute.api_id
  api_container_app_fqdn             = module.compute.api_fqdn
  web_container_app_id               = module.compute.web_id
  web_container_app_fqdn             = module.compute.web_fqdn
  container_app_environment_id       = module.compute.container_app_environment_id
  worker_container_app_id            = module.compute.worker_id
  frontdoor_private_link_enabled     = true
  # Prevention mode — signed off per GitHub issue #111. The /auth/* exclusion
  # set (QueryStringArgNames + RequestHeaderNames) is the approved mitigation;
  # any residual false positive on the sign-in POST body surfaces as a Block
  # on InitialBodyContents/DecodedInitialBodyContents in FrontDoorWebApplicationFirewallLog.
  frontdoor_waf_mode         = "Prevention"
  virtual_network_id         = data.azurerm_virtual_network.platform.id
  private_endpoint_subnet_id = data.azurerm_subnet.private_endpoints.id
  storage_account_id         = module.storage.storage_account_id
  storage_account_name       = module.storage.storage_account_name
  foundry_account_id         = local.foundry_account_id # null in byo-api: no Foundry private endpoint
}

# App-level diagnostics only. Firewall/NSG diagnostics and VNet flow logs are
# owned by the platform landing zone (where those resources live).
module "observability" {
  source                               = "../../../modules/observability"
  log_analytics_workspace_id           = data.azurerm_log_analytics_workspace.platform.id
  log_analytics_workspace_workspace_id = data.azurerm_log_analytics_workspace.platform.workspace_id
  log_analytics_workspace_location     = data.azurerm_log_analytics_workspace.platform.location
  diagnostic_setting_name_prefix       = local.name_prefix
  resource_group_name                  = data.azurerm_resource_group.this.name
  location                             = data.azurerm_resource_group.this.location
  tags                                 = local.tags

  diagnostic_targets = merge(
    {
      frontdoor_profile          = module.security.frontdoor_profile_id
      container_apps_environment = module.compute.container_app_environment_id
      container_app_web          = module.compute.web_id
      container_app_api          = module.compute.api_id
      container_app_worker       = module.compute.worker_id
      key_vault                  = module.identity.key_vault_id
      storage_account            = module.storage.storage_account_id
      postgres_server            = module.database.server_id
    },
    local.foundry_account_id != null ? { foundry_account = local.foundry_account_id } : {},
  )
}



# ─── Database ─────────────────────────────────────────────────────────────────
# PostgreSQL Flexible Server with VNet delegation (not private endpoint).
# The postgres private DNS zone is created in the security module and its ID
# is passed here. The server itself must be created AFTER the DNS zone + link.
module "database" {
  source                       = "../../../modules/database"
  resource_group_name          = data.azurerm_resource_group.this.name
  location                     = data.azurerm_resource_group.this.location
  name_prefix                  = local.name_prefix
  db_subnet_id                 = data.azurerm_subnet.database.id
  postgres_private_dns_zone_id = module.security.postgres_private_dns_zone_id
  admin_username               = var.postgres_admin_username
  admin_password               = var.postgres_admin_password
  tags                         = local.tags

  sku_name                     = "GP_Standard_D2s_v3"
  storage_mb                   = 65536
  backup_retention_days        = 30
  geo_redundant_backup_enabled = true
  high_availability_enabled    = true
}

# ─── GitHub Environment Variables ──────────────────────────────────────────────
# Pushing Terraform outputs back to the repository via the GitHub provider
# eliminates the need for the CI/CD pipeline to mutate repository state.
#
# Environment-scoped (not repository-scoped): CNA_NEXTAUTH_URL and KEY_VAULT_NAME
# are genuinely per-environment values (prod's Front Door host and vault name
# differ from dev's). A repository-scoped variable is a single value shared by
# both stacks — whichever environment applies last silently overwrites the
# other's value, which previously caused a dev run to pick up prod's Key Vault
# name (or vice versa).
#
# Written to BOTH "prod" and "hub": 211's apply job for prod authenticates
# under the `environment:hub` OIDC subject (the Prod SP's hub federated
# credential backs the approval gate), so `vars.*` in that job resolves against
# the hub environment, not prod — the same reason AZURE_CLIENT_ID is already
# written to both envs in Initialize-CnaGitHubSecrets.ps1. 211's plan/verify
# jobs and 340/360 use `environment: prod` directly and read the prod copy.
resource "github_actions_environment_variable" "cna_nextauth_url" {
  for_each      = toset(["prod", "hub"])
  repository    = var.github_repository
  environment   = each.key
  variable_name = "CNA_NEXTAUTH_URL"
  value         = var.nextauth_url
}

resource "github_actions_environment_variable" "key_vault_name" {
  for_each      = toset(["prod", "hub"])
  repository    = var.github_repository
  environment   = each.key
  variable_name = "KEY_VAULT_NAME"
  value         = module.identity.key_vault_name
}
