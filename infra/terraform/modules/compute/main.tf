# NOTE: the Log Analytics workspace was moved to the platform landing zone so
# platform-owned resources (firewall, NSGs, flow logs) are monitored in the same
# state that creates them. This module now consumes the workspace as an input
# (var.log_analytics_workspace_id) sourced from the platform root.

resource "azurerm_container_app_environment" "this" {
  name                               = local.container_apps_env_name
  location                           = var.location
  resource_group_name                = var.resource_group_name
  log_analytics_workspace_id         = var.log_analytics_workspace_id
  internal_load_balancer_enabled     = var.container_apps_internal_only
  public_network_access              = var.container_apps_public_network_access
  infrastructure_subnet_id           = var.infrastructure_subnet_id
  infrastructure_resource_group_name = local.container_apps_infra_resource_group_name
  tags                               = var.tags

  dynamic "workload_profile" {
    for_each = var.container_app_environment_workload_profiles
    content {
      name                  = workload_profile.value.name
      workload_profile_type = workload_profile.value.workload_profile_type
      minimum_count         = try(workload_profile.value.minimum_count, null)
      maximum_count         = try(workload_profile.value.maximum_count, null)
    }
  }
}

resource "azurerm_container_app" "api" {
  name                         = local.api_app_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = var.container_app_revision_mode
  tags                         = var.tags

  identity {
    type         = local.identity_type
    identity_ids = local.uai_ids
  }

  registry {
    server               = var.container_registry_server
    username             = local.use_registry_credentials ? var.container_registry_username : null
    password_secret_name = local.use_registry_credentials ? "container-registry-password" : null
    identity             = local.use_registry_credentials ? null : "system"
  }

  dynamic "secret" {
    for_each = local.use_registry_credentials ? [{ name = "container-registry-password" }] : []
    content {
      name  = secret.value.name
      value = var.container_registry_password
    }
  }

  dynamic "secret" {
    for_each = [for name in nonsensitive(keys(var.container_app_secrets)) : { name = name }]
    content {
      name  = secret.value.name
      value = var.container_app_secrets[secret.value.name]
    }
  }

  dynamic "secret" {
    for_each = local.kv_secrets_list
    content {
      name                = secret.value.name
      key_vault_secret_id = secret.value.uri
      identity            = var.key_vault_reference_identity_id
    }
  }

  template {
    # FinOps: scale_to_zero overrides min_replicas to 0 for dev environments.
    # When idle, Container Apps cost $0. Cold-start is ~5-10s.
    min_replicas = var.enable_scale_to_zero ? 0 : var.container_app_min_replicas
    max_replicas = var.container_app_max_replicas

    container {
      name   = "cna-api"
      image  = var.api_image
      cpu    = 0.5
      memory = "1Gi"

      # Liveness is a pure process check → /health (never touches the DB), so a
      # transient DB outage restarts nothing. Readiness and startup gate traffic
      # on real dependencies → /ready (runs SELECT 1), so a replica is only sent
      # requests once the database is reachable.
      liveness_probe {
        transport = "HTTP"
        port      = var.api_target_port
        path      = "/health"
      }

      readiness_probe {
        transport = "HTTP"
        port      = var.api_target_port
        path      = "/ready"
      }

      startup_probe {
        transport = "HTTP"
        port      = var.api_target_port
        path      = "/ready"
      }

      dynamic "env" {
        for_each = local.api_plain_env_vars
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.api_secret_env_vars
        content {
          name        = env.value.name
          secret_name = env.value.secret_name
        }
      }
    }
  }

  ingress {
    external_enabled = false # Internal only — Front Door routes to cna-web, not cna-api
    target_port      = var.api_target_port
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}

# ─── cna-web ──────────────────────────────────────────────────────────────────
# Next.js frontend + API routes. Public face of the CNA platform.
# Azure Front Door terminates TLS and WAF here. Port 3000.
resource "azurerm_container_app" "web" {
  name                         = local.web_app_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = var.container_app_revision_mode
  tags                         = var.tags

  identity {
    type         = local.identity_type
    identity_ids = local.uai_ids
  }

  registry {
    server               = var.container_registry_server
    username             = local.use_registry_credentials ? var.container_registry_username : null
    password_secret_name = local.use_registry_credentials ? "container-registry-password" : null
    identity             = local.use_registry_credentials ? null : "system"
  }

  dynamic "secret" {
    for_each = local.use_registry_credentials ? [{ name = "container-registry-password" }] : []
    content {
      name  = secret.value.name
      value = var.container_registry_password
    }
  }

  dynamic "secret" {
    for_each = [for name in nonsensitive(keys(var.container_app_secrets)) : { name = name }]
    content {
      name  = secret.value.name
      value = var.container_app_secrets[secret.value.name]
    }
  }

  dynamic "secret" {
    for_each = local.kv_secrets_list
    content {
      name                = secret.value.name
      key_vault_secret_id = secret.value.uri
      identity            = var.key_vault_reference_identity_id
    }
  }

  template {
    min_replicas = var.enable_scale_to_zero ? 0 : var.container_app_min_replicas
    max_replicas = var.container_app_max_replicas

    container {
      name   = "cna-web"
      image  = var.web_image
      cpu    = 0.5
      memory = "1Gi"

      liveness_probe {
        transport = "HTTP"
        port      = var.web_target_port
        path      = "/api/health"
      }

      readiness_probe {
        transport = "HTTP"
        port      = var.web_target_port
        path      = "/api/health"
      }

      startup_probe {
        transport = "HTTP"
        port      = var.web_target_port
        path      = "/api/health"
      }

      dynamic "env" {
        for_each = local.web_plain_env_vars
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.web_secret_env_vars
        content {
          name        = env.value.name
          secret_name = env.value.secret_name
        }
      }
    }
  }

  ingress {
    external_enabled = true # Public — Azure Front Door terminates TLS here
    target_port      = var.web_target_port
    transport        = "auto"

    # Phase 1 groundwork: support origin hardening without redesigning the
    # compute module. AzureRM currently supports CIDR-based restrictions here,
    # which is enough to introduce controlled ingress rules when the final
    # Front Door origin pattern is selected.
    dynamic "ip_security_restriction" {
      for_each = var.web_ingress_ip_security_restrictions
      content {
        name             = ip_security_restriction.value.name
        action           = ip_security_restriction.value.action
        ip_address_range = ip_security_restriction.value.ip_address_range
        description      = try(ip_security_restriction.value.description, null)
      }
    }

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}
