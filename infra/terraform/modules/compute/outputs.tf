output "container_app_environment_id" {
  value = azurerm_container_app_environment.this.id
}

output "api_id" {
  value = azurerm_container_app.api.id
}

output "api_name" {
  value = azurerm_container_app.api.name
}

output "api_fqdn" {
  value = azurerm_container_app.api.latest_revision_fqdn
}

output "web_id" {
  description = "CNA Web (Next.js) Container App resource ID"
  value       = azurerm_container_app.web.id
}

output "web_name" {
  description = "CNA Web (Next.js) Container App name"
  value       = azurerm_container_app.web.name
}

output "web_fqdn" {
  description = "CNA Web (Next.js) Container App stable ingress FQDN — used as Azure Front Door origin. Uses the revision-agnostic ingress FQDN so the AFD origin remains valid across revision updates."
  value       = azurerm_container_app.web.ingress[0].fqdn
}

# Log Analytics workspace outputs removed — the workspace now lives in the
# platform landing zone. Consume platform's outputs instead.

output "web_principal_id" {
  description = "System-assigned managed identity principal ID of the CNA Web Container App — used for RBAC assignments (e.g. Storage Blob Data Contributor)."
  value       = azurerm_container_app.web.identity[0].principal_id
}

output "api_principal_id" {
  description = "System-assigned managed identity principal ID of the CNA API Container App — used for RBAC assignments (e.g. Cognitive Services User, Storage Blob Data Contributor)."
  value       = azurerm_container_app.api.identity[0].principal_id
}
