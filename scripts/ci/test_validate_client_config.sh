#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${SCRIPT_DIR}/validate_client_config.sh"
export ENVIRONMENT=dev DEFAULT_BRANCH=trunk GITHUB_REF=refs/heads/trunk
export ARM_CLIENT_ID=11111111-1111-4111-8111-111111111111
export ARM_TENANT_ID=22222222-2222-4222-8222-222222222222
export ARM_SUBSCRIPTION_ID=33333333-3333-4333-8333-333333333333
export TFSTATE_RESOURCE_GROUP=rg-cna-dev-weu-tfstate TFSTATE_STORAGE_ACCOUNT=clientstate1234 TFSTATE_CONTAINER=tfstate
export AZURE_REGION_SHORT=weu AZURE_LOCATION=westeurope
export DOCKERHUB_NAMESPACE=upstream DOCKERHUB_TOKEN=synthetic-test-only
export IMAGE_SIGNING_IDENTITY=https://github.com/upstream/core/.github/workflows/200-build-images.yml@refs/heads/main
export CNA_ENTRA_CLIENT_ID=44444444-4444-4444-8444-444444444444
export CNA_NEXTAUTH_URL=https://assessment.client.test
export CNA_POSTGRES_ADMIN_PASSWORD=synthetic-test-only CNA_ENTRA_CLIENT_SECRET=synthetic-test-only CNA_NEXTAUTH_SECRET=synthetic-test-only
export CNA_CREDENTIAL_ENCRYPTION_KEY
CNA_CREDENTIAL_ENCRYPTION_KEY="$(printf '%032d' 0 | base64 | tr -d '\r\n')"
export GH_APP_ID=123 GH_APP_PRIVATE_KEY=synthetic-test-only AI_MODE=saas FOUNDRY_LOCATION=westeurope
unset LOCAL_ADMIN_PASSWORD
ENV_FILE="$(mktemp)"
CATALOG_DIR="$(mktemp -d)"
EMPTY_WORKSPACE="$(mktemp -d)"
trap 'rm -f -- "$ENV_FILE"; rm -rf -- "$CATALOG_DIR" "$EMPTY_WORKSPACE"' EXIT
export GITHUB_WORKSPACE="$EMPTY_WORKSPACE"

expect_failure() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "FAIL: ${name} was accepted" >&2
    exit 1
  fi
}
for mode in bootstrap deploy refresh teardown drift; do bash "$GUARD" "$mode"; done
punctuation_fixture='synthetic<test>only'
env CNA_ENTRA_CLIENT_SECRET="$punctuation_fixture" DOCKERHUB_TOKEN="$punctuation_fixture" bash "$GUARD" deploy
expect_failure "placeholder tenant" env ARM_TENANT_ID=00000000-0000-0000-0000-000000000000 bash "$GUARD" deploy
expect_failure "placeholder secret" env CNA_ENTRA_CLIENT_SECRET=PLACEHOLDER bash "$GUARD" deploy
expect_failure "non-secret angle brackets" env DOCKERHUB_NAMESPACE='upstream<test>' bash "$GUARD" deploy
expect_failure "placeholder domain" env CNA_NEXTAUTH_URL=https://cna.example.com bash "$GUARD" deploy
expect_failure "cross-environment backend" env TFSTATE_RESOURCE_GROUP=rg-cna-prod-weu-tfstate bash "$GUARD" deploy
expect_failure "plaintext break glass" env LOCAL_ADMIN_PASSWORD=not-a-hash bash "$GUARD" deploy
expect_failure "bad encryption key" env CNA_CREDENTIAL_ENCRYPTION_KEY=invalid bash "$GUARD" deploy
expect_failure "invalid blob container" env TFSTATE_CONTAINER=a bash "$GUARD" deploy
expect_failure "single-label domain" env CNA_NEXTAUTH_URL=https://internal bash "$GUARD" deploy
expect_failure "unknown environment" env ENVIRONMENT=../prod bash "$GUARD" teardown
expect_failure "prod feature branch" env ENVIRONMENT=prod TFSTATE_RESOURCE_GROUP=rg-cna-prod-weu-tfstate GITHUB_REF=refs/heads/feature bash "$GUARD" refresh
env ENVIRONMENT=prod TFSTATE_RESOURCE_GROUP=rg-cna-prod-weu-tfstate bash "$GUARD" teardown
expect_failure "empty BYO approval" env AI_MODE=byo-api CNA_AI_ENGINE_DEFAULT=openai CNA_BYO_AI_PROVIDERS='[]' bash "$GUARD" deploy
expect_failure "missing BYO approval" env -u CNA_BYO_AI_PROVIDERS AI_MODE=byo-api CNA_AI_ENGINE_DEFAULT=openai bash "$GUARD" deploy
expect_failure "placeholder BYO approval" env AI_MODE=byo-api CNA_AI_ENGINE_DEFAULT=openai CNA_BYO_AI_PROVIDERS='<CLIENT_APPROVED_PROVIDERS>' bash "$GUARD" deploy
expect_failure "wildcard BYO approval" env AI_MODE=byo-api CNA_AI_ENGINE_DEFAULT=openai CNA_BYO_AI_PROVIDERS='["*"]' bash "$GUARD" deploy
expect_failure "unapproved engine" env AI_MODE=byo-api CNA_AI_ENGINE_DEFAULT=anthropic CNA_BYO_AI_PROVIDERS='["openai"]' bash "$GUARD" deploy
expect_failure "duplicate BYO approval" env AI_MODE=byo-api CNA_AI_ENGINE_DEFAULT=openai CNA_BYO_AI_PROVIDERS='["openai","openai"]' bash "$GUARD" deploy
env AI_MODE=byo-api CNA_AI_ENGINE_DEFAULT=openai CNA_BYO_AI_PROVIDERS='["openai"]' bash "$GUARD" deploy
mkdir -p "$CATALOG_DIR/.deployment-catalog/dev"
printf '{"ai_mode":"saas"}' > "$CATALOG_DIR/.deployment-catalog/dev/latest.json"
expect_failure "existing Foundry names required" env GITHUB_WORKSPACE="$CATALOG_DIR" FOUNDRY_ACCOUNT_NAME= FOUNDRY_PROJECT_NAME= bash "$GUARD" deploy
env GITHUB_WORKSPACE="$CATALOG_DIR" FOUNDRY_ACCOUNT_NAME=cna-dev-eus2-aif2 FOUNDRY_PROJECT_NAME=client-existing-project bash "$GUARD" deploy
GITHUB_ENV="$ENV_FILE" bash "$GUARD" deploy --export
grep -Fxq 'TF_VAR_location=westeurope' "$ENV_FILE"
grep -Fxq 'TF_VAR_region_short=weu' "$ENV_FILE"
AI_MODE=byo-api CNA_AI_ENGINE_DEFAULT=openai CNA_BYO_AI_PROVIDERS='["openai"]' GITHUB_ENV="$ENV_FILE" bash "$GUARD" deploy --export
grep -Fxq 'TF_VAR_byo_ai_providers=["openai"]' "$ENV_FILE"
if grep -Fq 'synthetic-test-only' "$ENV_FILE"; then
  echo "FAIL: a runtime secret was persisted in the Terraform environment export" >&2
  exit 1
fi
echo "Client configuration regression tests passed."
