output "resource_group_name" {
  value = data.azurerm_resource_group.this.name
}

output "location" {
  value = data.azurerm_resource_group.this.location
}

output "storage_account_name" {
  value = module.storage.storage_account_name
}

output "storage_web_endpoint" {
  value = module.storage.primary_web_endpoint
}

output "key_vault_name" {
  value = module.identity.key_vault_name
}

output "managed_identity_client_id" {
  value = module.identity.managed_identity_client_id
}

output "managed_identity_id" {
  description = "Resource ID of the user-assigned managed identity used by the Container Apps."
  value       = module.identity.managed_identity_id
}

output "container_app_environment_id" {
  value = module.compute.container_app_environment_id
}

output "api_fqdn" {
  description = "CNA API Container App FQDN (internal — not directly reachable from internet)"
  value       = module.compute.api_fqdn
}

output "web_fqdn" {
  description = "CNA Web (Next.js) Container App FQDN"
  value       = module.compute.web_fqdn
}

output "web_name" {
  description = "CNA Web (Next.js) Container App name"
  value       = module.compute.web_name
}

# All four are null in byo-api mode (module.ai has count 0).
output "foundry_resource_group_name" {
  value = one(module.ai[*].foundry_resource_group_name)
}

output "foundry_account_name" {
  value = one(module.ai[*].foundry_account_name)
}

output "foundry_project_name" {
  value = one(module.ai[*].foundry_project_name)
}

output "foundry_endpoint" {
  value = one(module.ai[*].foundry_endpoint)
}

output "ai_mode" {
  description = "AI provisioning mode this workload was applied with (saas | byo-api). Recorded in the deployment manifest so image updates preserve it."
  value       = var.ai_mode
}

output "private_endpoint_subnet_prefix" {
  description = "CIDR prefix for the private endpoint subnet, used by post-deploy private DNS validation"
  value       = data.azurerm_subnet.private_endpoints.address_prefixes[0]
}

output "storage_role_assignment_id" {
  value = module.runtime.storage_role_assignment_id
}


output "frontdoor_endpoint_host_name" {
  description = "Azure Front Door endpoint hostname — this is the public URL for the platform"
  value       = module.security.frontdoor_endpoint_host_name
}

output "frontdoor_profile_id" {
  description = "Azure Front Door profile resource ID"
  value       = module.security.frontdoor_profile_id
}

output "frontdoor_endpoint_id" {
  description = "Azure Front Door endpoint resource ID"
  value       = module.security.frontdoor_endpoint_id
}

output "frontdoor_origin_group_id" {
  description = "Azure Front Door origin group resource ID"
  value       = module.security.frontdoor_origin_group_id
}

output "frontdoor_route_id" {
  description = "Azure Front Door route resource ID"
  value       = module.security.frontdoor_route_id
}

output "frontdoor_custom_domain_id" {
  description = "Azure Front Door custom domain resource ID"
  value       = module.security.frontdoor_custom_domain_id
}

output "frontdoor_secret_id" {
  description = "Azure Front Door secret resource ID"
  value       = module.security.frontdoor_secret_id
}

output "database_server_name" {
  description = "PostgreSQL Flexible Server name"
  value       = module.database.server_name
}

output "database_server_fqdn" {
  description = "PostgreSQL Flexible Server FQDN (private DNS name — only reachable within the VNet)"
  value       = module.database.server_fqdn
}

output "database_subnet_prefix" {
  description = "CIDR prefix for the PostgreSQL Flexible Server delegated subnet (used to derive the server's private IP)"
  value       = data.azurerm_subnet.database.address_prefixes[0]
}

output "database_connection_string" {
  description = "Full DATABASE_URL for the migrator job — used by CI to run prisma migrate deploy"
  value       = module.database.connection_string
  sensitive   = true
}

output "local_admin_password" {
  description = "PBKDF2 hash of the break-glass local admin password (or null if not configured) — passed to the migrator job by workflow 211 so it can seed/update the local admin user."
  value       = var.local_admin_password
  sensitive   = true
}
