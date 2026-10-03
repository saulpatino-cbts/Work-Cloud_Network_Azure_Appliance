#!/usr/bin/env bash
# Verify that an image this appliance is about to deploy was built and signed by
# the core's 200-build-images workflow (core TODO.md T-703). Shared across both
# appliances — keep byte-identical. Called by 210 (every image, before the plan)
# and 220 (every image named) after `docker login`, so cosign can read the
# signatures from the private Docker Hub repository:
#
#   scripts/ci/verify_image_signature.sh <role> <reference>
#
# Environment:
#   IMAGE_SIGNING_IDENTITY  (required) the exact Sigstore certificate identity of
#                           the signer — the core workflow's OIDC subject,
#                           https://github.com/<owner>/<core>/.github/workflows/200-build-images.yml@refs/heads/main
#   SIGSTORE_OIDC_ISSUER    (required) https://token.actions.githubusercontent.com
#
# Three checks, each fatal:
#   1. cosign verify             — a keyless signature on the digest whose
#                                  certificate carries exactly that identity and
#                                  issuer, recorded in the transparency log.
#   2. cosign verify-attestation — a SLSA v0.2 provenance attestation under the
#                                  same identity.
#   3. the statement's subject is the digest being deployed and its
#                                  predicate.builder.id names a workflow run of
#                                  the core repository the identity belongs to.
# The trusted identity comes from the repository variable only — never from the
# core's manifest, the dispatch payload or a workflow input.
set -euo pipefail

ROLE="${1:-}"
REF="${2:-}"
if [ -z "$ROLE" ] || [ -z "$REF" ]; then
  echo "::error::usage: verify_image_signature.sh <role> <reference>" >&2
  exit 1
fi
IDENTITY="${IMAGE_SIGNING_IDENTITY:-}"
ISSUER="${SIGSTORE_OIDC_ISSUER:-}"
IDENTITY_PATTERN='^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml@refs/heads/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$'
if [ -z "$IDENTITY" ]; then
  echo "::error::IMAGE_SIGNING_IDENTITY variable is required: the core 200-build-images workflow identity, https://github.com/<owner>/<core>/.github/workflows/200-build-images.yml@refs/heads/main (README.md → Configuration)." >&2
  exit 1
fi
if ! [[ "$IDENTITY" =~ $IDENTITY_PATTERN ]] || [[ "$IDENTITY" == *"/../"* || "$IDENTITY" == *"/.." || "$IDENTITY" == *"/./"* ]]; then
  echo "::error::IMAGE_SIGNING_IDENTITY '${IDENTITY}' is not a GitHub Actions workflow identity (https://github.com/<owner>/<repo>/.github/workflows/<file>.yml@refs/heads/<branch>)." >&2
  exit 1
fi
if [ -z "$ISSUER" ]; then
  echo "::error::SIGSTORE_OIDC_ISSUER is not set." >&2
  exit 1
fi
# https://github.com/<owner>/<core>: the identity up to /.github/.
CORE_REPO_URL="${IDENTITY%%/.github/*}"
EXPECTED_BUILDER_PREFIX="${CORE_REPO_URL}/actions/runs/"

EXPECTED_DIGEST=""
if [[ "$REF" =~ @sha256:([0-9a-f]{64})$ ]]; then
  EXPECTED_DIGEST="${BASH_REMATCH[1]}"
elif [[ "$REF" == *@* ]]; then
  echo "::error::${ROLE} image reference '${REF}' has a malformed digest suffix (expected @sha256:<64 lowercase hex>)." >&2
  exit 1
else
  echo "::warning::${ROLE} image reference '${REF}' carries no digest; the signature and attestation are checked against whatever the tag resolves to right now."
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# cosign 3 accepts exactly one proof of signing time per verification: an
# RFC 3161 signed timestamp from Sigstore's TSA (`--use-signed-timestamps`,
# required once the signing config points at Rekor v2) or Rekor v1's
# integrated timestamp (the default). Both time sources come from the same
# TUF-distributed trusted root, so either is an equally valid policy; the core
# signs with the signing config of the day, so try the TSA form first and fall
# back to the integrated timestamp. Identity, issuer and transparency-log
# inclusion are enforced identically on both paths.
cosign_verify_with_either_timestamp() {
  local out="$1"; shift
  if cosign "$@" --use-signed-timestamps > "$out" 2> "$WORK/stderr.tsa"; then
    echo "  (verified with a signed timestamp)"
    return 0
  fi
  if cosign "$@" > "$out" 2> "$WORK/stderr.tlog"; then
    echo "  (verified with the transparency-log integrated timestamp)"
    return 0
  fi
  echo "::error::${ROLE}: cosign ${1} failed for ${REF} with both timestamp policies." >&2
  echo "--- --use-signed-timestamps:" >&2; cat "$WORK/stderr.tsa" >&2
  echo "--- integrated timestamp:" >&2; cat "$WORK/stderr.tlog" >&2
  return 1
}

echo "${ROLE}: verifying signature on ${REF}"
cosign_verify_with_either_timestamp "$WORK/signatures.json" verify \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" \
  --output json "$REF"
if [ "$(jq 'if type == "array" then length else 0 end' "$WORK/signatures.json")" -lt 1 ]; then
  echo "::error::${ROLE}: cosign reported no signature for ${REF}." >&2
  exit 1
fi
if [ -n "$EXPECTED_DIGEST" ] && ! jq -e --arg d "sha256:${EXPECTED_DIGEST}" \
     'all(.[]; .critical.image["docker-manifest-digest"] == $d)' "$WORK/signatures.json" > /dev/null; then
  echo "::error::${ROLE}: the verified signature is on a different digest than ${REF}." >&2
  exit 1
fi

echo "${ROLE}: verifying SLSA provenance attestation"
cosign_verify_with_either_timestamp "$WORK/attestations.jsonl" verify-attestation \
  --type slsaprovenance02 \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" \
  "$REF"
# One DSSE envelope per line; the in-toto statement is its base64 payload.
: > "$WORK/statements.jsonl"
while IFS= read -r payload; do
  [ -n "$payload" ] || continue
  printf '%s' "$payload" | base64 -d >> "$WORK/statements.jsonl"
  echo >> "$WORK/statements.jsonl"
done < <(jq -r '.payload // empty' "$WORK/attestations.jsonl")

VERDICT="$(jq -s -r --arg d "$EXPECTED_DIGEST" --arg p "$EXPECTED_BUILDER_PREFIX" '
  map(select(.predicateType == "https://slsa.dev/provenance/v0.2"))
  | map({subjects: [.subject[]?.digest.sha256? // empty], builder: (.predicate.builder.id // "")})
  | map(select(($d == "" or (.subjects | index($d) != null)) and (.builder | startswith($p))))
  | if length > 0 then "ok " + .[0].builder else "none" end
' "$WORK/statements.jsonl")"
if [ "$VERDICT" = "none" ]; then
  echo "::error::${ROLE}: no SLSA v0.2 provenance on ${REF} has subject sha256:${EXPECTED_DIGEST:-<tag>} and a builder under ${EXPECTED_BUILDER_PREFIX}. Statements seen:" >&2
  jq -c '{predicateType, subjects: [.subject[]?.digest.sha256? // empty], builder: (.predicate.builder.id // "")}' "$WORK/statements.jsonl" >&2 || true
  exit 1
fi
echo "${ROLE}: signature and provenance verified — identity ${IDENTITY}, builder ${VERDICT#ok }"
