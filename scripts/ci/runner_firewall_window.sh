#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

MODE="${1:?prepare or cleanup required}"
[[ "$MODE" == prepare || "$MODE" == cleanup ]] || exit 2
: "${TFSTATE_RESOURCE_GROUP:?}"
[[ "$TFSTATE_RESOURCE_GROUP" == *-tfstate ]] || exit 2
RG="${TFSTATE_RESOURCE_GROUP%-tfstate}"
PREFIX="${RG#rg-}"
TAG=CnaRunnerIp
STORAGE_ONLY="${RUNNER_STORAGE_ACCOUNT:-}"
if [[ -n "$STORAGE_ONLY" ]]; then
  [[ "$STORAGE_ONLY" =~ ^[a-z0-9]{3,24}$ ]] || exit 2
fi

valid_ip() {
  local octet
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -ra octets <<< "$1"
  for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
}

# Tags are a durable journal, written before opening a rule. Never remove an
# unjournaled client rule. Serialized deploy/drift jobs reconcile abandoned leases.
reconcile() {
  local kind="$1" resources leases id name ip rules attempt cleared
  if [[ "$kind" == vault ]]; then
    resources=$(az keyvault list -g "$RG" -o json) || return 1
  else
    resources=$(az storage account list -g "$RG" -o json) || return 1
  fi
  jq -e 'type == "array"' <<< "$resources" >/dev/null || return 1
  if [[ -n "$STORAGE_ONLY" ]]; then
    resources=$(jq --arg name "$STORAGE_ONLY" '[.[] | select(.name == $name)]' <<< "$resources") || return 1
  fi
  leases=$(jq -r --arg tag "$TAG" '.[] | select(.tags[$tag] != null) | [.id,.name,.tags[$tag]] | @tsv' <<< "$resources") || return 1
  while IFS=$'\t' read -r id name ip; do
    ip="${ip%$'\r'}"
    [[ -n "$id" ]] || continue
    valid_ip "$ip" || { echo "::error::Invalid runner lease on $name; operator reconciliation required." >&2; return 1; }
    cleared=false
    for attempt in 1 2 3; do
      if [[ "$kind" == vault ]]; then
        if az keyvault network-rule remove --name "$name" -g "$RG" --ip-address "$ip" --only-show-errors -o none; then
          rules=$(az keyvault show --name "$name" -g "$RG" --query 'properties.networkAcls.ipRules[].value' -o json) || return 1
        else
          rules='["removal-failed"]'
        fi
      else
        if az storage account network-rule remove --account-name "$name" -g "$RG" --ip-address "$ip" --only-show-errors -o none; then
          rules=$(az storage account show --name "$name" -g "$RG" --query 'networkRuleSet.ipRules[].ipAddressOrRange' -o json) || return 1
        else
          rules='["removal-failed"]'
        fi
      fi
      if [[ "$rules" != '["removal-failed"]' ]] &&
         jq -e --arg ip "$ip" 'all(.[]; . != $ip and . != ($ip + "/32"))' <<< "$rules" >/dev/null; then
        cleared=true
        break
      fi
      sleep 5
    done
    if [[ "$cleared" != true ]]; then
      echo "::error::Runner firewall cleanup failed on $name; lease retained for retry. Block client traffic and reconcile." >&2
      return 1
    fi
    az tag update --resource-id "$id" --operation Delete --tags "$TAG" --only-show-errors -o none || return 1
  done <<< "$leases"
}

STATUS=0
if [[ -z "$STORAGE_ONLY" ]]; then reconcile vault || STATUS=1; fi
reconcile storage || STATUS=1
[[ "$STATUS" == 0 ]] || exit 1
if [[ "$MODE" == prepare ]]; then
  if [[ -z "$STORAGE_ONLY" ]]; then
  accounts=$(az cognitiveservices account list -g "$RG" --query "[?kind=='AIServices'].name" -o json)
  jq -e 'type == "array"' <<< "$accounts" >/dev/null
  if jq -e 'length > 0' <<< "$accounts" >/dev/null; then
    : "${TF_VAR_foundry_account_name:?Existing Foundry requires an explicit account name}"
    : "${TF_VAR_foundry_project_name:?Existing Foundry requires an explicit project name}"
    jq -e --arg name "$TF_VAR_foundry_account_name" 'index($name) != null' <<< "$accounts" >/dev/null ||
      { echo "::error::Configured Foundry name does not match an existing account; review migration before planning." >&2; exit 1; }
    account_id=$(az cognitiveservices account show -g "$RG" --name "$TF_VAR_foundry_account_name" --query id -o tsv)
    account_id="${account_id%$'\r'}"
    [[ "$account_id" == /subscriptions/*/resourceGroups/"$RG"/providers/Microsoft.CognitiveServices/accounts/"$TF_VAR_foundry_account_name" ]] ||
      { echo "::error::Unexpected Foundry account scope." >&2; exit 1; }
    projects=$(az rest --method get --url "https://management.azure.com${account_id}/projects?api-version=2025-06-01" -o json)
    jq -e --arg name "$TF_VAR_foundry_project_name" --arg id "$account_id/projects/$TF_VAR_foundry_project_name" \
      '.value | type == "array" and any(.[]; .name == $name and (.id | ascii_downcase) == ($id | ascii_downcase))' <<< "$projects" >/dev/null ||
      { echo "::error::Existing Foundry project identity does not match; review migration before planning." >&2; exit 1; }
  fi
  fi
  IP=$(curl -fsS https://api.ipify.org)
  valid_ip "$IP" || { echo "::error::A valid runner IPv4 is required." >&2; exit 1; }
  : "${GITHUB_ENV:?}"
  printf 'TF_VAR_deploy_runner_ip=%s\nRUNNER_FIREWALL_IP=%s\n' "$IP" "$IP" >> "$GITHUB_ENV"
  for kind in vault storage; do
    if [[ -n "$STORAGE_ONLY" && "$kind" == vault ]]; then continue; fi
    if [[ "$kind" == vault ]]; then
      resources=$(az keyvault list -g "$RG" -o json)
      filter='select(.name | startswith($prefix + "-kv"))'
    else
      resources=$(az storage account list -g "$RG" -o json)
      filter='select(.tags.Project == "cna" or .tags.ManagedBy == "terraform")'
    fi
    jq -e 'type == "array"' <<< "$resources" >/dev/null
    if [[ -n "$STORAGE_ONLY" ]]; then
      resources=$(jq --arg name "$STORAGE_ONLY" '[.[] | select(.name == $name)]' <<< "$resources")
      jq -e 'length == 1' <<< "$resources" >/dev/null ||
        { echo "::error::Portal storage must exist in the selected workload resource group." >&2; exit 1; }
      filter='.'
    fi
    ids=$(jq -r --arg prefix "$PREFIX" ".[] | $filter | .id" <<< "$resources")
    while IFS= read -r id; do
      id="${id%$'\r'}"
      [[ -n "$id" ]] || continue
      name=$(jq -er --arg id "$id" '.[] | select(.id == $id) | .name' <<< "$resources")
      name="${name%$'\r'}"
      if [[ "$kind" == vault ]]; then
        rules=$(az keyvault show --name "$name" -g "$RG" --query 'properties.networkAcls.ipRules[].value' -o json)
      else
        rules=$(az storage account show --name "$name" -g "$RG" --query 'networkRuleSet.ipRules[].ipAddressOrRange' -o json)
      fi
      jq -e --arg ip "$IP" 'all(.[]; . != $ip and . != ($ip + "/32"))' <<< "$rules" >/dev/null ||
        { echo "::error::Runner IP already has an unjournaled rule on $name; operator must establish ownership." >&2; exit 1; }
      az tag update --resource-id "$id" --operation Merge --tags "$TAG=$IP" --only-show-errors -o none
    done <<< "$ids"
  done
fi
