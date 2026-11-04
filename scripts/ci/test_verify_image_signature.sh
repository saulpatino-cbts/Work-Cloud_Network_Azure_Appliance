#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="${SCRIPT_DIR}/verify_image_signature.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for command in base64 grep jq; do
  if ! command -v "$command" > /dev/null; then
    echo "Missing required test command: ${command}" >&2
    exit 1
  fi
done

mkdir "$WORK/bin"
cat > "$WORK/bin/cosign" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' invoked >> "${MOCK_COSIGN_MARKER:?}"
COMMAND="$1"
shift
ARGS=("$@")

has_option() {
  local i
  for ((i = 0; i < ${#ARGS[@]} - 1; i++)); do
    if [[ "${ARGS[i]}" == "$1" && "${ARGS[i + 1]}" == "$2" ]]; then
      return 0
    fi
  done
  return 1
}

has_option --certificate-identity "${IMAGE_SIGNING_IDENTITY:?}" || exit 10
has_option --certificate-oidc-issuer "${SIGSTORE_OIDC_ISSUER:?}" || exit 11

if [[ "${MOCK_FAIL_SIGNED_TIMESTAMP:-0}" == "1" ]]; then
  for argument in "${ARGS[@]}"; do
    if [[ "$argument" == "--use-signed-timestamps" ]]; then
      echo "mock TSA verification failure" >&2
      exit 1
    fi
  done
fi

case "$COMMAND" in
  verify)
    printf '%s\n' "${MOCK_SIGNATURES_JSON:?}"
    ;;
  verify-attestation)
    has_option --type slsaprovenance02 || exit 12
    printf '%s\n' "${MOCK_ATTESTATIONS_JSON:?}"
    ;;
  *)
    exit 13
    ;;
esac
MOCK
chmod +x "$WORK/bin/cosign"

export PATH="${WORK}/bin:${PATH}"
export IMAGE_SIGNING_IDENTITY="https://github.com/acme/Work-Cloud_Network_Core/.github/workflows/200-build-images.yml@refs/heads/main"
export SIGSTORE_OIDC_ISSUER="https://token.actions.githubusercontent.com"
export MOCK_COSIGN_MARKER="${WORK}/cosign-invoked"

DIGEST="0000000000000000000000000000000000000000000000000000000000000000"
OTHER_DIGEST="1111111111111111111111111111111111111111111111111111111111111111"
BUILDER="https://github.com/acme/Work-Cloud_Network_Core/actions/runs/123456789"
OTHER_BUILDER="https://github.com/attacker/other/actions/runs/123456789"
PINNED_REF="docker.io/acme/cna:api-sha-1234567@sha256:${DIGEST}"
TAG_ONLY_REF="docker.io/acme/cna:api-sha-1234567"

make_statement() {
  jq -cn --arg digest "$1" --arg builder "$2" '{
    predicateType: "https://slsa.dev/provenance/v0.2",
    subject: [{name: "cna-api", digest: {sha256: $digest}}],
    predicate: {builder: {id: $builder}}
  }'
}

make_envelope() {
  local statement="$1"
  local payload
  payload="$(printf '%s' "$statement" | base64 | tr -d '\r\n')"
  jq -cn --arg payload "$payload" '{
    payloadType: "application/vnd.in-toto+json",
    payload: $payload,
    signatures: [{sig: "mock-signature"}]
  }'
}

expect_failure() {
  local description="$1"
  local expected="$2"
  shift 2
  if "$VERIFIER" "$@" > "$WORK/stdout" 2> "$WORK/stderr"; then
    echo "FAIL: ${description} unexpectedly succeeded" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$WORK/stderr"; then
    echo "FAIL: ${description} did not report '${expected}'" >&2
    cat "$WORK/stderr" >&2
    exit 1
  fi
}

export MOCK_SIGNATURES_JSON
MOCK_SIGNATURES_JSON="$(jq -cn --arg digest "sha256:${DIGEST}" '[{critical:{image:{"docker-manifest-digest":$digest}}}]')"
export MOCK_SIGNATURES_JSON
export MOCK_ATTESTATIONS_JSON
MOCK_ATTESTATIONS_JSON="$(make_envelope "$(make_statement "$DIGEST" "$BUILDER")")"
export MOCK_ATTESTATIONS_JSON

rm -f "$MOCK_COSIGN_MARKER"
expect_failure "tag-only reference" "not digest-pinned" api "$TAG_ONLY_REF"
if [[ -e "$MOCK_COSIGN_MARKER" ]]; then
  echo "FAIL: cosign was invoked for a tag-only reference" >&2
  exit 1
fi

expect_failure "malformed digest reference" "malformed digest suffix" api "${PINNED_REF%?}z"

MOCK_SIGNATURES_JSON="not-json"
export MOCK_SIGNATURES_JSON
expect_failure "malformed signature JSON" "malformed signature JSON" api "$PINNED_REF"

MOCK_SIGNATURES_JSON="$(jq -cn --arg digest "sha256:${OTHER_DIGEST}" '[{critical:{image:{"docker-manifest-digest":$digest}}}]')"
export MOCK_SIGNATURES_JSON
expect_failure "signature digest mismatch" "different digest" api "$PINNED_REF"

MOCK_SIGNATURES_JSON="$(jq -cn --arg digest "sha256:${DIGEST}" '[{critical:{image:{"docker-manifest-digest":$digest}}}]')"
MOCK_ATTESTATIONS_JSON="not-json"
export MOCK_SIGNATURES_JSON MOCK_ATTESTATIONS_JSON
expect_failure "malformed attestation JSON" "malformed attestation JSON" api "$PINNED_REF"

MOCK_ATTESTATIONS_JSON="$(make_envelope "$(make_statement "$OTHER_DIGEST" "$BUILDER")")"
export MOCK_ATTESTATIONS_JSON
expect_failure "attestation subject mismatch" "no SLSA v0.2 provenance" api "$PINNED_REF"

MOCK_ATTESTATIONS_JSON='{"payload":"***","payloadType":"application/vnd.in-toto+json"}'
export MOCK_ATTESTATIONS_JSON
expect_failure "invalid DSSE base64 payload" "invalid base64 DSSE payload" api "$PINNED_REF"

MOCK_ATTESTATIONS_JSON='{"unsupported":"shape"}'
export MOCK_ATTESTATIONS_JSON
expect_failure "unsupported attestation shape" "unsupported attestation shape" api "$PINNED_REF"

MOCK_ATTESTATIONS_JSON="$(make_envelope "$(make_statement "$DIGEST" "$OTHER_BUILDER")")"
export MOCK_ATTESTATIONS_JSON
expect_failure "attestation builder mismatch" "no SLSA v0.2 provenance" api "$PINNED_REF"

MOCK_ATTESTATIONS_JSON="$(make_envelope "$(make_statement "$DIGEST" "$BUILDER")")"
MOCK_ATTESTATIONS_JSON="$(jq -cn --argjson envelope "$MOCK_ATTESTATIONS_JSON" '[$envelope]')"
MOCK_FAIL_SIGNED_TIMESTAMP=1
export MOCK_ATTESTATIONS_JSON MOCK_FAIL_SIGNED_TIMESTAMP
if ! "$VERIFIER" api "$PINNED_REF" > "$WORK/stdout" 2> "$WORK/stderr"; then
  echo "FAIL: valid DSSE envelope was rejected" >&2
  cat "$WORK/stderr" >&2
  exit 1
fi
grep -Fq "verified with the transparency-log integrated timestamp" "$WORK/stdout"
grep -Fq "signature and provenance verified" "$WORK/stdout"

MOCK_ATTESTATIONS_JSON="$(make_statement "$DIGEST" "$BUILDER")"
MOCK_FAIL_SIGNED_TIMESTAMP=0
export MOCK_ATTESTATIONS_JSON MOCK_FAIL_SIGNED_TIMESTAMP
if ! "$VERIFIER" api "$PINNED_REF" > "$WORK/stdout" 2> "$WORK/stderr"; then
  echo "FAIL: valid direct statement was rejected" >&2
  cat "$WORK/stderr" >&2
  exit 1
fi
grep -Fq "signature and provenance verified" "$WORK/stdout"

echo "Image-signature verifier regression tests passed."
