variable "api_image" {
  description = "Container image for CNA API, pinned reference docker.io/<namespace>/cna:api-sha-<7>@sha256:<digest>"
  type        = string
}

variable "web_image" {
  description = "Container image for CNA Web (Next.js 15), pinned reference docker.io/<namespace>/cna:web-sha-<7>@sha256:<digest>"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name for compute resources"
  type        = string
}

variable "location" {
  description = "Azure location"
  type        = string
}

variable "name_prefix" {
  description = "Normalized name prefix for compute resources"
  type        = string
}

variable "tags" {
  description = "Tags applied to compute resources"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "container_registry_server" {
  description = "Container registry server used by Container Apps"
  type        = string
  default     = "docker.io"
}

variable "container_registry_username" {
  description = "Username for private container registry pulls. Required for Docker Hub private repositories."
  type        = string
  default     = ""
}

variable "container_registry_password" {
  description = "Token or password for private container registry pulls. Required for Docker Hub private repositories."
  type        = string
  sensitive   = true
  default     = ""
}

variable "container_app_min_replicas" {
  description = "Minimum replicas for Container Apps"
  type        = number
  default     = 1
}

variable "container_app_max_replicas" {
  description = "Maximum replicas for Container Apps"
  type        = number
  default     = 3
}

variable "container_app_revision_mode" {
  description = "Revision mode for Container Apps"
  type        = string
  default     = "Single"
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace (created in the platform landing zone) that the Container App Environment and app diagnostics send to."
  type        = string
}

# FinOps: scale-to-zero for idle environments
variable "enable_scale_to_zero" {
  description = "Override min_replicas to 0 for all Container Apps. Major cost saving for dev (no charge when idle). Not recommended for prod — adds cold-start latency."
  type        = bool
  default     = false
}

variable "api_target_port" {
  description = "Ingress target port for API container app"
  type        = number
  default     = 8080
}

variable "web_target_port" {
  description = "Ingress target port for web container app (Next.js)"
  type        = number
  default     = 3000
}

variable "api_env_vars" {
  description = "Plain environment variables for the API container app"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "web_env_vars" {
  description = "Plain environment variables for the web container app"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "api_secret_env_vars" {
  description = "Secret-backed env vars for the API Container App. Map key is env var name, value is secret name."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "web_secret_env_vars" {
  description = "Secret-backed env vars for the web Container App. Map key is env var name, value is secret name."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "container_app_secrets" {
  description = "Secrets injected into all Container Apps. Map key is secret name, value is secret value."
  type        = map(string)
  default     = {}
  nullable    = false
  sensitive   = true

  validation {
    # Secret names are unique per Container App across all sources (registry
    # password, plain secrets, KV references). A collision fails at the
    # Container Apps API during apply, not at `terraform plan` — catching it
    # here surfaces the error immediately instead of mid-apply.
    condition     = length(setintersection(nonsensitive(keys(var.container_app_secrets)), keys(var.container_app_kv_secrets))) == 0
    error_message = "container_app_secrets and container_app_kv_secrets must not share secret names — each Container App secret name must be unique across all sources."
  }
}

variable "container_apps_internal_only" {
  description = "Whether the Container Apps environment should use an internal load balancer. Set false to allow the web Container App to have external ingress."
  type        = bool
  default     = false
}

variable "container_apps_public_network_access" {
  description = "Public network access mode for the Container Apps environment. Set to Disabled when Azure Front Door reaches the app over Private Link."
  type        = string
  default     = "Enabled"

  validation {
    condition     = contains(["Enabled", "Disabled"], var.container_apps_public_network_access)
    error_message = "container_apps_public_network_access must be Enabled or Disabled."
  }
}

variable "container_app_environment_workload_profiles" {
  description = "Optional workload profiles for the Container Apps environment. Required for features such as Azure Front Door Private Link origins."
  type = list(object({
    name                  = string
    workload_profile_type = string
    minimum_count         = optional(number)
    maximum_count         = optional(number)
  }))
  default  = []
  nullable = false
}

variable "web_ingress_ip_security_restrictions" {
  description = "Optional IP-based ingress restrictions for the public web Container App. Use this to constrain direct-origin access when the selected edge pattern cannot yet use private origins."
  type = list(object({
    name             = string
    action           = string
    ip_address_range = string
    description      = optional(string)
  }))
  default  = []
  nullable = false
}

variable "infrastructure_subnet_id" {
  description = "Subnet ID delegated to the Container Apps managed environment infrastructure"
  type        = string
  default     = null
}

variable "container_app_environment_infrastructure_resource_group_name" {
  description = "Deterministic name for the Azure-managed infrastructure resource group that backs the Container Apps environment."
  type        = string
  default     = null
}

variable "key_vault_reference_identity_id" {
  description = "Resource ID of the user-assigned managed identity used to read Key Vault secret references. Required when container_app_kv_secrets is non-empty."
  type        = string
  default     = null
}

variable "container_app_kv_secrets" {
  description = "Key Vault secret references for Container Apps. Map key is secret name; value is a versionless KV secret URI (e.g. https://vault.vault.azure.net/secrets/mysecret). Azure auto-refreshes these within 30 min when the secret version changes."
  type        = map(string)
  default     = {}
  nullable    = false
}
