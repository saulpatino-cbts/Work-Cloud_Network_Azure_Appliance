#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export MOCK_DIR="$TMP" TFSTATE_RESOURCE_GROUP=rg-cna-dev-eus2-tfstate
export GITHUB_ENV="$TMP/env" PATH="$TMP:$PATH"
cat > "$TMP/az" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_DIR/calls"
case "$*" in
  "keyvault list"*) cat "$MOCK_DIR/vaults" ;;
  "storage account list"*) cat "$MOCK_DIR/storage" ;;
  "cognitiveservices account list"*) cat "$MOCK_DIR/accounts" ;;
  "cognitiveservices account show"*) printf '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-cna-dev-eus2/providers/Microsoft.CognitiveServices/accounts/cna-dev-eus2-aif2' ;;
  "rest --method get"*) cat "$MOCK_DIR/projects" ;;
  "keyvault network-rule remove"*|"storage account network-rule remove"*)
    n=$(cat "$MOCK_DIR/attempts"); echo "$((n+1))" > "$MOCK_DIR/attempts"
    [[ "${MOCK_FAIL:-}" != always ]] || exit 1
    [[ "${MOCK_FAIL:-}" != once || "$n" -gt 0 ]] || exit 1
    [[ "${MOCK_STALE:-}" == true ]] || printf '["198.51.100.8"]' > "$MOCK_DIR/rules"
    ;;
  "keyvault show"*|"storage account show"*) cat "$MOCK_DIR/rules" ;;
  "tag update"*) ;;
  *) echo "Unexpected mocked command: $*" >&2; exit 99 ;;
esac
MOCK
printf '#!/usr/bin/env bash\nprintf 192.0.2.10\n' > "$TMP/curl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/sleep"
chmod +x "$TMP/az" "$TMP/curl" "$TMP/sleep"

reset() {
  printf '[{"id":"/vault","name":"cna-dev-eus2-kv","tags":{"CnaRunnerIp":"192.0.2.10"}}]' > "$TMP/vaults"
  printf '[{"id":"/storage","name":"clientstorage","tags":{"CnaRunnerIp":"192.0.2.10","ManagedBy":"terraform"}}]' > "$TMP/storage"
  printf '["192.0.2.10","198.51.100.8"]' > "$TMP/rules"
  printf '[]' > "$TMP/accounts"
  printf '{"value":[{"name":"client-existing-project","id":"/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-cna-dev-eus2/providers/Microsoft.CognitiveServices/accounts/cna-dev-eus2-aif2/projects/client-existing-project"}]}' > "$TMP/projects"
  echo 0 > "$TMP/attempts"
  : > "$TMP/calls"
  : > "$TMP/env"
}
reject() {
  if "$@" > "$TMP/output" 2>&1; then
    echo "Expected failure: $*" >&2; exit 1
  fi
}
reset
bash "$ROOT/scripts/ci/runner_firewall_window.sh" cleanup
grep -q 'operation Delete' "$TMP/calls"
[[ "$(cat "$TMP/rules")" == '["198.51.100.8"]' ]]
reset
MOCK_FAIL=once bash "$ROOT/scripts/ci/runner_firewall_window.sh" cleanup
[[ "$(cat "$TMP/attempts")" -ge 3 ]]
reset
reject env MOCK_FAIL=always bash "$ROOT/scripts/ci/runner_firewall_window.sh" cleanup
! grep -q 'operation Delete' "$TMP/calls"
[[ "$(cat "$TMP/attempts")" == 6 ]]
reset
reject env MOCK_STALE=true bash "$ROOT/scripts/ci/runner_firewall_window.sh" cleanup
! grep -q 'operation Delete' "$TMP/calls"
reset
# Simulate a new job after hard termination: journal survives, runner state does not.
bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
grep -Fxq 'TF_VAR_deploy_runner_ip=192.0.2.10' "$TMP/env"
[[ "$(grep -c 'operation Delete' "$TMP/calls")" == 2 ]]
[[ "$(grep -c 'operation Merge' "$TMP/calls")" == 2 ]]
reset
printf '["cna-dev-eus2-aif2"]' > "$TMP/accounts"
reject bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
! grep -q 'operation Merge' "$TMP/calls"
reset
printf '["cna-dev-eus2-aif2"]' > "$TMP/accounts"
TF_VAR_foundry_account_name=cna-dev-eus2-aif2 TF_VAR_foundry_project_name=client-existing-project \
  bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
reset
printf '["cna-dev-eus2-aif2"]' > "$TMP/accounts"
reject env TF_VAR_foundry_account_name=cna-dev-eus2-aif TF_VAR_foundry_project_name=client-existing-project \
  bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
reset
printf '[{"id":"/vault","name":"cna-dev-eus2-kv","tags":{}}]' > "$TMP/vaults"
printf '[]' > "$TMP/storage"
reject bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
! grep -q 'network-rule remove' "$TMP/calls"
! grep -q 'operation Merge' "$TMP/calls"
reset
printf 'not-json' > "$TMP/vaults"
printf '[]' > "$TMP/storage"
reject bash "$ROOT/scripts/ci/runner_firewall_window.sh" cleanup
! grep -q 'operation Delete' "$TMP/calls"
reset
printf '[{"id":"/vault","name":"cna-dev-eus2-kv","tags":{"CnaRunnerIp":"invalid"}}]' > "$TMP/vaults"
printf '[]' > "$TMP/storage"
reject bash "$ROOT/scripts/ci/runner_firewall_window.sh" cleanup
! grep -q 'network-rule remove' "$TMP/calls"
reset
printf '["cna-dev-eus2-aif2"]' > "$TMP/accounts"
reject env TF_VAR_foundry_account_name=cna-dev-eus2-aif2 TF_VAR_foundry_project_name=wrong-project \
  bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
reset
printf '["cna-dev-eus2-aif2"]' > "$TMP/accounts"
printf '{"value":[]}' > "$TMP/projects"
reject env TF_VAR_foundry_account_name=cna-dev-eus2-aif2 TF_VAR_foundry_project_name=client-existing-project \
  bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
reset
printf '["cna-dev-eus2-aif2"]' > "$TMP/accounts"
printf '{"value":[{"name":"client-existing-project","id":"/wrong-parent/projects/client-existing-project"}]}' > "$TMP/projects"
reject env TF_VAR_foundry_account_name=cna-dev-eus2-aif2 TF_VAR_foundry_project_name=client-existing-project \
  bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
reset
RUNNER_STORAGE_ACCOUNT=clientstorage bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
! grep -q '^keyvault ' "$TMP/calls"
! grep -q '^cognitiveservices ' "$TMP/calls"
[[ "$(grep -c 'operation Delete' "$TMP/calls")" == 1 ]]
[[ "$(grep -c 'operation Merge' "$TMP/calls")" == 1 ]]
reset
reject env RUNNER_STORAGE_ACCOUNT=foreignstorage bash "$ROOT/scripts/ci/runner_firewall_window.sh" prepare
! grep -q 'operation Merge' "$TMP/calls"
reset
reject env RUNNER_STORAGE_ACCOUNT=clientstorage MOCK_FAIL=always bash "$ROOT/scripts/ci/runner_firewall_window.sh" cleanup
! grep -q 'operation Delete' "$TMP/calls"
echo "Runner firewall lease regression tests passed (17 scenarios, including project name/identity mismatch, absence and scoped portal lifecycle)."
