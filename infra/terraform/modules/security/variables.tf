variable "resource_group_name" {
  description = "Resource group name containing the Key Vault"
  type        = string
}

variable "private_endpoint_settle_duration" {
  description = "Stabilization delay before creating private endpoints, allowing their target resources (Cognitive Services/Foundry account, storage, Key Vault) to reach a terminal provisioning state. Prevents 'RequestConflict: provisioning state is not terminal' on private endpoint creation."
  type        = string
  default     = "45s"
}

variable "location" {
  description = "Azure location"
  type        = string
}

variable "name_prefix" {
  description = "Normalized name prefix for security resources"
  type        = string
}

variable "frontdoor_waf_mode" {
  description = "Azure Front Door WAF policy mode. Signed off as 'Prevention' per GitHub issue #111 — the /auth/* exclusion set (QueryStringArgNames for OAuth callback params, RequestHeaderNames for the Auth.js Next-Action header) is the approved mitigation for the DefaultRuleSet 1.0 false positives on the sign-in path."
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Detection", "Prevention"], var.frontdoor_waf_mode)
    error_message = "frontdoor_waf_mode must be Detection or Prevention."
  }
}

variable "key_vault_id" {
  description = "Key Vault resource ID"
  type        = string
}

variable "key_vault_name" {
  description = "Key Vault name"
  type        = string
}

variable "api_container_app_id" {
  description = "API Container App resource ID"
  type        = string
}

variable "api_container_app_fqdn" {
  description = "API Container App FQDN (internal, kept for reference)"
  type        = string
}

variable "web_container_app_fqdn" {
  description = "Web (Next.js) Container App FQDN — used as Azure Front Door origin host"
  type        = string
}

variable "web_container_app_id" {
  description = "Web (Next.js) Container App resource ID"
  type        = string
}

variable "container_app_environment_id" {
  description = "Container Apps managed environment resource ID used for Front Door Private Link"
  type        = string
}

variable "frontdoor_custom_domain_host_name" {
  description = "Optional custom domain hostname for Azure Front Door"
  type        = string
  default     = ""
}

variable "frontdoor_custom_domain_dns_zone_id" {
  description = "Optional Azure DNS zone resource ID for Front Door custom domain integration"
  type        = string
  default     = null
}

variable "frontdoor_certificate_type" {
  description = "Certificate type for Front Door custom domain TLS"
  type        = string
  default     = "ManagedCertificate"
}

variable "frontdoor_minimum_tls_version" {
  description = "Minimum TLS version for Front Door custom domain TLS"
  type        = string
  default     = "TLS12"
}

variable "frontdoor_secret_versionless_id" {
  description = "Optional Key Vault certificate secret versionless ID for customer-managed Front Door TLS"
  type        = string
  default     = null
}

variable "frontdoor_private_link_enabled" {
  description = "Whether Azure Front Door should connect to the Container Apps origin over Private Link."
  type        = bool
  default     = false
}

variable "frontdoor_private_link_target_type" {
  description = "Target subresource used for the Front Door Private Link origin."
  type        = string
  default     = "managedEnvironments"
}

variable "frontdoor_private_link_request_message" {
  description = "Request message used when Azure Front Door creates the private endpoint connection."
  type        = string
  default     = "Azure Front Door Private Link request for CNA web origin"
}

variable "virtual_network_id" {
  description = "Virtual network ID used for private DNS links"
  type        = string
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID used for private endpoints"
  type        = string
}

variable "storage_account_id" {
  description = "Storage account resource ID for private endpoint"
  type        = string
}

variable "storage_account_name" {
  description = "Storage account name for private DNS wiring"
  type        = string
}

variable "foundry_account_id" {
  description = "Azure AI Foundry account resource ID for private endpoint wiring. Null skips the Foundry private endpoint (ai_mode = byo-api provisions no Foundry account)."
  type        = string
  default     = null
}

variable "secret_expiration_date" {
  description = "RFC3339 expiration timestamp applied to Terraform-managed Key Vault secrets"
  type        = string
  default     = "2027-12-31T23:59:59Z"
}
variable "frontdoor_certificate_pfx_path" {
  description = "File path to the PFX certificate for Front Door"
  type        = string
  default     = null
}

variable "frontdoor_certificate_pfx_password" {
  description = "Password for the PFX certificate"
  type        = string
  sensitive   = true
  default     = null
}
