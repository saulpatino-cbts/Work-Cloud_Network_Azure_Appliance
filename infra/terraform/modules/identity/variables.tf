variable "bootstrap_ip_rules" {
  description = "Temporary deployment-runner IP rules at vault creation; workflows remove these after Terraform. Runtime traffic uses Private Link."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "resource_group_name" {
  description = "Resource group name for identity resources"
  type        = string
}

variable "location" {
  description = "Azure location"
  type        = string
}

variable "name_prefix" {
  description = "Normalized name prefix for identity resources"
  type        = string
}

variable "tenant_id" {
  description = "Azure tenant ID"
  type        = string
}

variable "tags" {
  description = "Tags applied to identity resources"
  type        = map(string)
  default     = {}
  nullable    = false
}

# FinOps / Zero Trust — Key Vault hardening
variable "key_vault_soft_delete_retention_days" {
  description = "Soft-delete retention for Key Vault. Minimum 7 days; set to 90 when purge_protection is enabled."
  type        = number
  default     = 7
}

variable "key_vault_purge_protection_enabled" {
  description = "Enable purge protection on Key Vault. Required for prod — prevents accidental permanent deletion of secrets. Defaults to true: purge protection cannot be disabled once enabled, so a false default would let any caller who omits this variable silently end up with weaker protection than every environment that explicitly sets it, with no way to reconcile after the fact."
  type        = bool
  default     = true
  nullable    = false
}

variable "key_vault_name_suffix" {
  description = "Optional suffix appended to the Key Vault name. Increment (e.g. '2', '3') after a full teardown to avoid soft-delete name conflicts."
  type        = string
  default     = ""
}
