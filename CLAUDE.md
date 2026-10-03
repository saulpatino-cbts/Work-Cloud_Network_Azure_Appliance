# CLAUDE.md — Cloud Network Assessment Azure Appliance

Instructions for AI coding agents working in this repository. `README.md` is the
human intro page; this file states the rules an agent must not infer wrongly.

## What this repository is — and is not

This is the **Azure appliance** for the Cloud Network Assessment (CNA)
platform: Azure Terraform plus the workflows that deploy, update,
watch and tear down an environment. It runs container images built by the
**core** repository, <https://github.com/saulpatinojr/Work-Cloud_Network_Core>.

- **Application code never lives here.** No `apps/`, no `cna/`, no Dockerfiles.
  A feature is implemented once in the core; both appliances receive it through
  the images (`docker.io/<namespace>/cna:{api,worker,web,migrator}-sha-<7>`).
- **Nothing for AWS lives here.** The sibling appliance is
  <https://github.com/saulpatinojr/Work-Cloud_Network_AWS_Appliance>. Do not add AWS
  Terraform, actions, secrets, regions or wording to this repository.

## The two appliances are identical — mirror every change

This repository and the sibling are the same repository except for the
cloud-specific list in `README.md` → "Identical to the sibling, except". That
means:

1. **Any structural change is made in both repositories in the same change
   set**: a workflow edit, a new input, a script, a catalog-schema change, a
   document, a convention. Open the sibling pull request alongside this one and
   link them, or — if you genuinely cannot — add a `TODO.md` item here that
   names the sibling and the exact change. Never leave the mirror implied.
2. **Workflow numbers, names and inputs are shared** with the core and the
   sibling. Never renumber, rename or change an input's contract unilaterally.
3. **Cloud-specific edits stay inside the cloud-specific files** (the Terraform
   module bodies, the OIDC login step, the state backend, the vault, the fast
   redeploy command, the SaaS engine wiring, the publish storage). If an edit
   touches anything else, it is a shared change — see rule 1.

## The core ↔ appliance contract (read-only from here)

These are defined by the core and consumed here. Changing them starts in the
core and is mirrored into both appliances by the core's own `CLAUDE.md` rule:

- Image tag scheme on Docker Hub (immutable `*-sha-<7>`, floating `*-latest`).
- `.deployment-catalog/latest-build.json` in the core (fields `sha_tag`,
  `commit`, `built_at`, `run_id`, `images{}`) — what `230-image-update` reads.
- `repository_dispatch` event `cna-image-published` with that manifest as the
  payload — what `230-image-update` listens for.
- The runtime environment contract Terraform injects into the images:
  `CNA_AI_MODE` (`saas` | `byo-api`), `CNA_APPLIANCE_CLOUD` (`azure`),
  `CNA_AI_ENGINE_DEFAULT`, the SaaS engine variables (`AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_API_VERSION`, `FOUNDRY_*`), and
  `CREDENTIAL_ENCRYPTION_KEY`.
- Image signatures and provenance: the core's `200-build-images` signs every
  published digest with cosign, keyless, under its workflow identity
  (`https://github.com/<owner>/<core>/.github/workflows/200-build-images.yml@refs/heads/main`,
  issuer `https://token.actions.githubusercontent.com`) and attaches BuildKit's
  SLSA v0.2 provenance (`slsaprovenance02`, `builder.id` = the run URL). `210`
  and `220` verify all of it with `scripts/ci/verify_image_signature.sh`
  against the `IMAGE_SIGNING_IDENTITY` variable — the only place the trusted
  identity lives — before any deploy; an unsigned or foreign image never
  reaches a plan. `COSIGN_VERSION` is pinned identically here and in the core.

## Deployment rules

- **`ai_mode` is chosen in the Run-workflow dialog** and recorded in the release
  catalog. `230-image-update` passes the recorded mode through unchanged — an
  image update must never flip it. Flipping a live environment between `saas`
  and `byo-api` destroys or creates the cloud AI resources: it needs a
  `REVIEW.md` entry and a human decision first.
- **The BYO AI API keys are entered only on the app's AI Engine page.** Never
  accept an AI key (or any secret) through a `workflow_dispatch` input, a
  Terraform variable value, a repository variable, or a file in this repository.
- **`.deployment-catalog/` is owned by workflows.** `210-deploy` writes it,
  `230-image-update` and `350`/`360` read it. Never hand-edit it; never delete
  archives.
- **`220-fast-redeploy` bypasses Terraform and the catalog.** It is for
  emergencies; it must be followed by a real `210` release.
- **Prod is human-gated.** The `apply` job runs under the `hub` environment and
  waits for its required reviewers. `230` only opens an issue for prod; it never
  deploys it.
- **Secrets travel as GitHub secrets → OIDC / Azure Key Vault → `TF_VAR_*` env or
  container secrets.** Never as `-var` on a command line, never in a dispatch
  input, never committed.

## Repository conventions

- **Documents:** `README.md`, `CHANGELOG.md`, `REVIEW.md`, `TODO.md` and this
  `CLAUDE.md` are the only markdown files (plus `.github/ISSUE_TEMPLATE/`).
  `scripts/validate_documentation_model.py` enforces this in `300-validate`.
  Long-form documentation goes to the core's Wiki.
- **Never hardcode a value at a call site.** Declare it as a Terraform variable
  and resolve at runtime. Variables a human must supply take no default.
- **Every GitHub Action is pinned to a SHA digest.** `detect-secrets` fails the
  build on any finding not in `.secrets.baseline`; the baseline holds only
  hand-audited false positives (this repository does not enable the inline
  pragma filter — a pragma comment does nothing).
- Start with `TODO.md` when picking up work; check `REVIEW.md` when blocked on a
  human decision.
- **Working a backlog item** (this `TODO.md`, or the appliance half of a core
  `T-7xx`) follows the core's `.claude/orchestration/workflows.md` → W12 from a
  session holding both appliance checkouts: spec → a specialist implements → a
  *different* agent verifies → findings folded → checks → docs → draft PR;
  humans merge. Shared files are edited once and copied byte-identically; the
  delivery step diffs the sibling's hunks. Definition of done here, on the
  final tree: `actionlint` on every changed workflow; `pre-commit run
  detect-secrets --all-files` (stage the relocated `.secrets.baseline`);
  `scripts/validate_documentation_model.py`; `terraform fmt -check -recursive`
  and `terraform validate` on every root a Terraform change touches; the
  sibling PR opened and linked, with the merge order when it matters. Never
  merge, never `terraform apply`, never deploy — `210` under `hub` is the human
  gate.
