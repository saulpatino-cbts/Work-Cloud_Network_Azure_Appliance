locals {
  name_prefix = "${var.project_name}-${var.environment}-${var.region_short}"
  tags = {
    Environment = title(var.environment)
    CostCenter  = "CNA"
    Owner       = "cna-platform"
    Project     = var.project_name
    ManagedBy   = "terraform"
  }

  # Registry pull credential — the Container Apps pull with it and the web tier
  # reuses the same secret (read-only) for its image-update check. Mirrors the
  # compute module's own condition.
  use_registry_credentials = nonsensitive(var.container_registry_username != "" && var.container_registry_password != "")

  # Image-update check contract (apps/cna-web/lib/image-update.ts): the web
  # tier compares its baked build SHA with the newest published build under the
  # image's floating tag and links to this repository's 230/210 workflows.
  image_update_env_vars = {
    CNA_WEB_IMAGE               = var.web_image
    CNA_IMAGE_REGISTRY_USERNAME = var.container_registry_username
    CNA_APPLIANCE_REPO          = "${var.github_owner}/${var.github_repository}"
  }

  # ── AI mode ─────────────────────────────────────────────────────────────────
  ai_saas               = var.ai_mode == "saas"
  foundry_account_name  = var.foundry_account_name != "" ? var.foundry_account_name : "${local.name_prefix}-aif"
  foundry_project_name  = var.foundry_project_name != "" ? var.foundry_project_name : "${local.foundry_account_name}-proj"
  azure_openai_endpoint = var.azure_openai_endpoint != "" ? var.azure_openai_endpoint : "https://${local.foundry_account_name}.services.ai.azure.com"

  # null when module.ai is not instantiated (byo-api). one() on the module splat
  # is the zero-or-one accessor; it never indexes into an empty list.
  foundry_account_id = one(module.ai[*].foundry_account_id)

  # Mode-independent runtime contract, injected into both apps. The app
  # resolves its engine family from these (apps/cna-web/lib/ai-engine-rules.ts,
  # cna/ai_engine/chat_agent.py).
  ai_mode_env_vars = merge({
    CNA_AI_MODE           = var.ai_mode
    CNA_APPLIANCE_CLOUD   = "azure"
    CNA_AI_ENGINE_DEFAULT = var.ai_engine_default
    }, local.ai_saas ? {} : {
    CNA_BYO_AI_PROVIDERS = jsonencode(sort(tolist(var.byo_ai_providers)))
  })

  # saas-only env. Empty in byo-api so AZURE_OPENAI_* / FOUNDRY_* are absent and
  # the Azure OpenAI engine reports unconfigured on both tiers.
  azure_ai_env_vars = local.ai_saas ? {
    FOUNDRY_PROJECT_ENDPOINT        = var.foundry_project_endpoint
    FOUNDRY_RECOMMENDATION_AGENT_ID = var.foundry_recommendation_agent_id
    AZURE_OPENAI_ENDPOINT           = local.azure_openai_endpoint
    AZURE_OPENAI_DEPLOYMENT         = var.azure_openai_deployment
    AZURE_OPENAI_API_VERSION        = var.azure_openai_api_version
  } : {}

  optional_outbound_urls = compact([
    trimspace(var.azure_mcp_endpoint) != "" && lower(trimspace(var.azure_mcp_endpoint)) != "none" && startswith(lower(trimspace(var.azure_mcp_endpoint)), "http") ? trimspace(var.azure_mcp_endpoint) : null,
    trimspace(var.aws_mcp_endpoint) != "" && lower(trimspace(var.aws_mcp_endpoint)) != "none" && startswith(lower(trimspace(var.aws_mcp_endpoint)), "http") ? trimspace(var.aws_mcp_endpoint) : null,
    trimspace(var.drawio_mcp_url) != "" && lower(trimspace(var.drawio_mcp_url)) != "none" && startswith(lower(trimspace(var.drawio_mcp_url)), "http") ? trimspace(var.drawio_mcp_url) : null,
  ])

  optional_outbound_fqdns = [
    for url in local.optional_outbound_urls : split("/", replace(replace(url, "https://", ""), "http://", ""))[0]
  ]

  # Host the web app calls for Azure OpenAI (the AIServices account's
  # services.ai.azure.com endpoint). Allowed through the egress firewall.
  azure_openai_endpoint_host = split(
    "/",
    replace(
      replace(local.azure_openai_endpoint, "https://", ""),
      "http://",
      ""
    )
  )[0]

  key_vault_host = split("/", trimprefix(module.identity.key_vault_uri, "https://"))[0]

  firewall_application_rule_fqdns = sort(distinct(concat(
    [
      split("/", var.api_image)[0],
      split("/", var.web_image)[0],
      "index.docker.io",
      "registry-1.docker.io",
      "auth.docker.io",
      "production.cloudfront.docker.com",
      "pkg-containers.githubusercontent.com",
      "${module.storage.storage_account_name}.blob.core.windows.net",
      local.key_vault_host,
      local.azure_openai_endpoint_host,
      "login.microsoftonline.com",
      "management.azure.com",
    ],
    local.optional_outbound_fqdns,
  )))
}
