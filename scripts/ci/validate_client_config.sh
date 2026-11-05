#!/usr/bin/env bash
set -euo pipefail

# Validates configuration only. Never contacts Azure or prints supplied values.
MODE="${1:?Usage: validate_client_config.sh bootstrap|deploy|refresh|teardown|drift}"
fail() { echo "::error::Client configuration: $1" >&2; exit 1; }
required() {
  local name="$1" value="${!1:-}" lower secret="${2:-false}"
  lower="${value,,}"
  [[ -n "${value//[[:space:]]/}" ]] || fail "$name is required."
  case "$lower" in
    none|null|changeme|change-me|todo|*placeholder*|*replace_me*|*replace-me*|*example.com*|*example.invalid*)
      fail "$name contains an unfilled placeholder."
      ;;
  esac
  if [[ "$secret" != true && ( "$value" == *'<'* || "$value" == *'>'* ) ]]; then
    fail "$name contains an unfilled placeholder."
  fi
}
uuid() {
  required "$1"
  [[ "${!1}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ &&
     "${!1}" != 00000000-0000-0000-0000-000000000000 ]] || fail "$1 must be a nonzero UUID."
}

case "$MODE" in bootstrap|deploy|refresh|teardown|drift) ;; *) fail "Unknown validation mode." ;; esac
[[ "${ENVIRONMENT:-}" == dev || "${ENVIRONMENT:-}" == prod ]] || fail "ENVIRONMENT must be dev or prod."
required DEFAULT_BRANCH
if [[ "$ENVIRONMENT" == prod ]]; then
  [[ "${GITHUB_REF:-}" == "refs/heads/${DEFAULT_BRANCH}" ]] || fail "Production operations require the repository default branch."
fi
for name in ARM_CLIENT_ID ARM_TENANT_ID ARM_SUBSCRIPTION_ID; do uuid "$name"; done

for name in TFSTATE_RESOURCE_GROUP TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER AZURE_REGION_SHORT; do required "$name"; done
[[ "$AZURE_REGION_SHORT" =~ ^[a-z0-9]{2,8}$ ]] || fail "AZURE_REGION_SHORT must contain 2-8 lowercase letters/digits."
# All roots currently derive the workload RG from this exact convention.
[[ "$TFSTATE_RESOURCE_GROUP" == "rg-cna-${ENVIRONMENT}-${AZURE_REGION_SHORT}-tfstate" ]] || fail "TFSTATE_RESOURCE_GROUP must match the selected environment and region."
[[ "$TFSTATE_STORAGE_ACCOUNT" =~ ^[a-z0-9]{3,24}$ && "$TFSTATE_STORAGE_ACCOUNT" != stcnatfstate0001 ]] || fail "TFSTATE_STORAGE_ACCOUNT must be a client-owned name (3-24 lowercase letters/digits), not the old example."
[[ "$TFSTATE_CONTAINER" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ &&
   "$TFSTATE_CONTAINER" != *--* ]] || fail "TFSTATE_CONTAINER must be a valid blob container name."

if [[ "$MODE" == bootstrap || "$MODE" == deploy || "$MODE" == drift ]]; then
  required AZURE_LOCATION
  [[ "$AZURE_LOCATION" =~ ^[a-z0-9]+$ ]] || fail "AZURE_LOCATION must be an Azure region identifier."
fi
if [[ "$MODE" == refresh || "$MODE" == deploy ]]; then
  required DOCKERHUB_NAMESPACE
  [[ "$DOCKERHUB_NAMESPACE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "DOCKERHUB_NAMESPACE has an invalid shape."
  required DOCKERHUB_TOKEN true
  required IMAGE_SIGNING_IDENTITY
  [[ "$IMAGE_SIGNING_IDENTITY" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/200-build-images\.yml@refs/heads/[A-Za-z0-9_./-]+$ ]] || fail "IMAGE_SIGNING_IDENTITY must identify the actual upstream signing workflow."
fi
if [[ "$MODE" == deploy || "$MODE" == drift ]]; then
  printf '%s' "${CNA_BYO_AI_PROVIDERS:-[]}" | jq -se '
    length == 1 and (.[0] | type == "array" and length == (unique | length)
    and all(.[]; . == "anthropic" or . == "openai"))
  ' > /dev/null || fail "CNA_BYO_AI_PROVIDERS must be one JSON array of unique anthropic/openai providers."
  for name in FOUNDRY_LOCATION FOUNDRY_ACCOUNT_NAME FOUNDRY_PROJECT_NAME; do
    if [[ -n "${!name:-}" ]]; then
      required "$name"
      [[ "${!name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || fail "$name must be a resource name without whitespace."
    fi
  done
  catalog="${GITHUB_WORKSPACE:-.}/.deployment-catalog/${ENVIRONMENT}/latest.json"
  if [[ -f "$catalog" ]] && [[ "$(jq -er '.ai_mode' "$catalog")" == saas ]]; then
    required FOUNDRY_ACCOUNT_NAME
    required FOUNDRY_PROJECT_NAME
  fi
fi
if [[ "$MODE" == deploy ]]; then
  uuid CNA_ENTRA_CLIENT_ID
  required CNA_NEXTAUTH_URL
  [[ "$CNA_NEXTAUTH_URL" =~ ^https://([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ &&
     "$CNA_NEXTAUTH_URL" != *localhost* ]] || fail "CNA_NEXTAUTH_URL must be a client HTTPS origin without a path, query or credentials."
  required GH_APP_ID
  for name in CNA_POSTGRES_ADMIN_PASSWORD CNA_ENTRA_CLIENT_SECRET CNA_NEXTAUTH_SECRET CNA_CREDENTIAL_ENCRYPTION_KEY GH_APP_PRIVATE_KEY; do required "$name" true; done
  key_bytes="$(printf '%s' "$CNA_CREDENTIAL_ENCRYPTION_KEY" | base64 -d 2>/dev/null | wc -c)" || fail "CNA_CREDENTIAL_ENCRYPTION_KEY must be base64."
  [[ "$key_bytes" -eq 32 ]] || fail "CNA_CREDENTIAL_ENCRYPTION_KEY must decode to 32 bytes."
  if [[ -n "${LOCAL_ADMIN_PASSWORD:-}" ]]; then
    [[ "$LOCAL_ADMIN_PASSWORD" =~ ^pbkdf2\$sha256\$210000\$[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=$ ]] || fail "LOCAL_ADMIN_PASSWORD must be the supported PBKDF2 hash, never plaintext."
  fi
  case "${AI_MODE:-}" in
    saas)
      required FOUNDRY_LOCATION
      [[ "$FOUNDRY_LOCATION" =~ ^[a-z0-9]+$ ]] || fail "FOUNDRY_LOCATION must be a client-approved Azure region."
      ;;
    byo-api)
      printf '%s' "${CNA_BYO_AI_PROVIDERS:-[]}" | jq -e '
        type == "array" and length > 0 and length == (unique | length)
        and all(.[]; . == "anthropic" or . == "openai")
      ' > /dev/null || fail "CNA_BYO_AI_PROVIDERS must be a nonempty JSON array of approved anthropic/openai providers."
      printf '%s' "$CNA_BYO_AI_PROVIDERS" | jq -e --arg engine "${CNA_AI_ENGINE_DEFAULT:-}" 'index($engine) != null' > /dev/null ||
        fail "CNA_AI_ENGINE_DEFAULT must name one of the approved BYO providers."
      ;;
    *) fail "AI_MODE must be saas or byo-api." ;;
  esac
fi
if [[ "${2:-}" == --export ]]; then
  [[ ( "$MODE" == deploy || "$MODE" == drift ) && -n "${GITHUB_ENV:-}" ]] || fail "--export is only supported for deploy/drift on a workflow runner."
  # Resolve environment-scoped values at step runtime, not workflow expansion.
  # Never persist runtime secret values in GITHUB_ENV.
  for name in ARM_CLIENT_ID ARM_TENANT_ID ARM_SUBSCRIPTION_ID DOCKERHUB_NAMESPACE IMAGE_SIGNING_IDENTITY TFSTATE_RESOURCE_GROUP TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER AZURE_REGION_SHORT; do
    if [[ -n "${!name:-}" ]]; then printf '%s=%s\n' "$name" "${!name}" >> "$GITHUB_ENV"; fi
  done
  printf 'TF_VAR_tenant_id=%s\nTF_VAR_location=%s\nTF_VAR_region_short=%s\n' "$ARM_TENANT_ID" "$AZURE_LOCATION" "$AZURE_REGION_SHORT" >> "$GITHUB_ENV"
  printf 'TF_VAR_foundry_location=%s\nTF_VAR_foundry_account_name=%s\nTF_VAR_foundry_project_name=%s\n' "${FOUNDRY_LOCATION:-}" "${FOUNDRY_ACCOUNT_NAME:-}" "${FOUNDRY_PROJECT_NAME:-}" >> "$GITHUB_ENV"
  printf 'TF_VAR_byo_ai_providers=%s\n' "$(printf '%s' "${CNA_BYO_AI_PROVIDERS:-[]}" | jq -c .)" >> "$GITHUB_ENV"
fi
echo "Client configuration validated (${MODE}); no cloud operations performed."
