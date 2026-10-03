# Cloud Network Assessment (CNA) — Azure Appliance

[![Validate](https://github.com/saulpatinojr/Work-Cloud_Network_Azure_Appliance/actions/workflows/300-validate.yml/badge.svg)](https://github.com/saulpatinojr/Work-Cloud_Network_Azure_Appliance/actions/workflows/300-validate.yml)

This repository deploys and operates the **Cloud Network Assessment platform on Azure**.
It contains the Azure Terraform and the workflows that deploy, update, watch and tear
down an environment — and nothing else. The application itself (web, API, worker, CLI) lives in
the **core** repository, [`Work-Cloud_Network_Core`](https://github.com/saulpatinojr/Work-Cloud_Network_Core),
which builds the container images this appliance runs. Features ship once, in those images; this
appliance picks them up.

Its sibling, [`Work-Cloud_Network_AWS_Appliance`](https://github.com/saulpatinojr/Work-Cloud_Network_AWS_Appliance), does the same
for AWS. **The two appliances are identical** — same file names, workflow numbers and
inputs, release-catalog schema, scripts and documents — except for the cloud-specific parts listed
below. If you change something here that is not on that list, change it in the sibling too.

---

## What is here, and what is not

| Here | Not here |
|---|---|
| `infra/terraform/` — Azure modules and the `dev` / `prod` environment roots (platform + workload, split state) | Application code — `apps/`, `cna/`, Dockerfiles (core) |
| `.github/workflows/` — bootstrap, validate, deploy, fast redeploy, image update, publish, teardown, key sync, drift | Image builds — `200-build-images.yml` (core) |
| `.deployment-catalog/{dev,prod}/` — the release catalog every deploy writes (images, `ai_mode`, evidence) | Anything for AWS |
| `scripts/` — bootstrap and CI evidence helpers | Long-form documentation — the core's [Wiki](https://github.com/saulpatinojr/Work-Cloud_Network_Core/wiki) |

### Identical to the sibling, except

| Cloud-specific in this appliance | Here (Azure) | Sibling (AWS) |
|---|---|---|
| Terraform module implementations (`infra/terraform/modules/*`) | Container Apps, PostgreSQL Flexible Server, Key Vault, Front Door + WAF, Azure Firewall, AI Foundry | ECS Fargate + ALB, RDS PostgreSQL, Secrets Manager, CloudFront + WAF, Bedrock |
| Terraform state backend and `000-bootstrap-backend` inputs | `azurerm`: storage account + container (`location`, `region_short`, `tfstate_resource_group`, `tfstate_storage_account`, `tfstate_container`) | `s3` + DynamoDB lock table (`region`, `region_short`, `tfstate_bucket`, `tfstate_lock_table`) |
| CI identity (OIDC) and its secret names | `azure/login` — `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | `aws-actions/configure-aws-credentials` — `AWS_DEPLOY_ROLE_ARN` |
| Runtime secret store | Azure Key Vault | AWS Secrets Manager |
| Fast redeploy command (`220-fast-redeploy`) | `az containerapp update` | `aws ecs update-service` |
| SaaS AI engine (`ai_mode: saas`) | Azure OpenAI on the AI Foundry account (`azure-openai`) | Amazon Bedrock (`bedrock`) |
| Delivery-portal storage (`320-publish-portal`) | Azure Blob Storage (private per-engagement container, SAS access) | Amazon S3 |

Everything else — workflow numbers, names and inputs; `210-deploy`'s three-job shape and evidence
gates; `230-image-update`'s behaviour; the catalog schema; `README.md`/`CLAUDE.md` structure — is
the same file in both repositories.

---

## Documentation map

Four documents plus `CLAUDE.md`; everything long-form is in the core's Wiki.

| Document | Contains |
|---|---|
| `README.md` (this file) | What this appliance is, how to operate it, configuration, conventions |
| [`CHANGELOG.md`](CHANGELOG.md) | Completed work in this repository, by release |
| [`REVIEW.md`](REVIEW.md) | Blockers that require a human decision, approval, or access grant |
| [`TODO.md`](TODO.md) | The engineering work queue for this appliance |
| [`CLAUDE.md`](CLAUDE.md) | Rules for AI coding agents — above all: app code lives in the core, and every structural change is mirrored to the sibling |

---

## Repository layout

```
.github/workflows/
├── 000-bootstrap-backend.yml   Create the Terraform state backend (once per environment)
├── 100-validate-prereqs.yml    Read-only preflight: secrets, variables, identity, registries
├── 210-deploy.yml              Full release or rollback: policy gates → plan → apply → verify
├── 220-fast-redeploy.yml       Image-only rollout for emergencies (does not update the catalog)
├── 230-image-update.yml        Picks up new core images: auto-deploys dev, opens the prod request
├── 300-validate.yml            CI for this repository: secrets scan, docs guard, terraform fmt/validate
├── 320-publish-portal.yml      Publish an engagement's client portal to Azure Blob Storage
├── 330-teardown.yml            Destroy an environment (typed confirmation required)
├── 350-drift-dev.yml           Daily drift detection against the dev release catalog
├── 360-drift-prod.yml          Drift detection for prod (manual until prod exists)
└── 380-project-board.yml       Adds new issues and PRs to the shared project board (inert until core R-012)
.github/ISSUE_TEMPLATE/update-available.md   The prod update request 230 opens
.deployment-catalog/{dev,prod}/              Release catalog: latest.json + one archive per run
infra/terraform/
├── modules/{ai,compute,database,identity,observability,runtime,security,storage}
└── environments/{dev,prod}/{platform,workload}
scripts/                                     ci/ evidence helpers, setup helpers, docs guard
```

---

## Operating the appliance

Every operation is a workflow run from the **Actions → Run workflow** dialog, in band order.

### First deploy of an environment

1. **`000 · Bootstrap Backend`** — creates the Terraform state backend for the environment.
2. **`100 · Validate Prerequisites`** — read-only check that every secret, variable and identity
   the deploy needs is in place. Fix what it reports before going on.
3. **`210 · Deploy`** — `environment: dev` (or `prod`), `deploy_mode: release`, and **`ai_mode`**:
   - **`saas`** — Terraform provisions Azure OpenAI on the AI Foundry account and the app authenticates with its
     workload identity. Nothing to enter in the app.
   - **`byo-api`** — for locations where Azure OpenAI on the AI Foundry account is unavailable. **No cloud AI resources
     are provisioned.** After the deploy, an admin opens **AI Engine** in the app and pastes an
     Anthropic and/or OpenAI API key — these are the only secrets ever entered in the app UI; they
     are stored encrypted in the database. With one key that provider is used automatically; with
     both, a toggle on the same page chooses.

   The image inputs are **pinned references** of the form
   `docker.io/<namespace>/cna:<role>-sha-<7>@sha256:<digest>` — supply one per role (api, worker,
   web, migrator). `230 · Image Update` fills them in automatically; to run `210` by hand, copy them
   from the core's `.deployment-catalog/latest-build.json` (`images.<role>` + `digests.<role>`) or
   from the `update-available` issue. Floating tags (`*-latest`, `:latest`) and empty values are
   refused. `prod` applies run under the `hub` environment and wait for its required reviewers.

   Before the plan, `210` verifies every image's cosign signature and SLSA provenance against
   `IMAGE_SIGNING_IDENTITY` (the core's `200-build-images` identity); `220` does the same for each
   image it rolls. An image the core did not build and sign is refused, whatever its tag says.

Flipping `ai_mode` on a live environment destroys or creates the cloud AI resources — record the
decision in `REVIEW.md` first.

### Staying current

**`230 · Image Update`** runs when the core publishes images (`repository_dispatch`) and every six
hours as a safety net. It compares the core's build manifest with `.deployment-catalog/<env>/latest.json`:

- **dev** is redeployed automatically through `210` with the same `ai_mode` it already has
  (`AUTO_UPDATE_DEV` variable, default on).
- **prod** gets an issue labelled `update-available` with the exact image references and a link to
  the `210` dialog. A human runs it; the `hub` approval gate applies.

An environment that has never been deployed is never touched by `230`.

### Everything else

- **Rollback:** `210` with `deploy_mode: rollback` and the three `previous_*_image` references
  from `.deployment-catalog/<env>/latest.json` (or a `<run_id>.json` archive); the migrator comes
  from the same catalog record (`workflow_call` callers may pass `previous_migrator_image`).
- **Emergency image swap:** `220` — fast, but it bypasses Terraform and the catalog; follow with a
  real `210` release.
- **Drift:** `350` (dev, daily) and `360` (prod, manual) plan against the deployed images and
  `ai_mode` from the catalog and warn on differences. A check that *fails* — or finds that the
  environment no longer exists — opens (or updates) one issue assigned to the repository owner.
- **Teardown:** `330` — type `DESTROY`; optionally also destroy the state backend.
- **Client portal:** `320` publishes an engagement's deliverables to Azure Blob Storage.

---

## Configuration

Configuration comes from three places, in this order of authority:

1. **GitHub Secrets and Variables** — the source of truth. Cloud credentials use OIDC; there are
   no long-lived keys. Secrets are never `workflow_dispatch` inputs and never `-var` values.
2. **Azure Key Vault** — runtime secrets for a deployed environment (read directly with `az keyvault secret show` under your own identity).
3. **The app's AI Engine page** — only the bring-your-own AI API keys, only in `byo-api` mode.

| Kind | Name | Purpose |
|---|---|---|
| Secret | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | OIDC identity for every workflow |
| Secret | `FRONTDOOR_CERTIFICATE_PFX_PASSWORD` | Front Door certificate (`100` checks it, `210` verify uses it) |
| Secret | `GH_APP_ID`, `GH_APP_PRIVATE_KEY` | GitHub App used to read the core's build manifest (`230`) and to manage repository variables |
| Secret | `DOCKERHUB_TOKEN` | Pull access for the private `cna` images |
| Secret | `CNA_POSTGRES_ADMIN_PASSWORD`, `CNA_ENTRA_CLIENT_SECRET`, `CNA_NEXTAUTH_SECRET`, `CNA_CREDENTIAL_ENCRYPTION_KEY` | Runtime secrets Terraform writes to Azure Key Vault (`100` checks them) |
| Variable | `CORE_REPO` | Core repository name (`Work-Cloud_Network_Core`) — where `230` polls the manifest |
| Variable | `IMAGE_SIGNING_IDENTITY` | The core's signing identity, `https://github.com/<owner>/<core>/.github/workflows/200-build-images.yml@refs/heads/main` — `210` and `220` refuse any image whose signature and provenance do not verify against it (`100` checks it is set) |
| Variable | `DOCKERHUB_NAMESPACE` | Docker Hub namespace of the `cna` images |
| Variable | `AUTO_UPDATE_DEV` | `false` freezes dev; anything else lets `230` redeploy it |
| Variable | `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER`, `AZURE_REGION_SHORT`, `AZURE_TARGET_SUBSCRIPTION_NAME` | State backend and region for the roots |
| Variable | `CNA_ENTRA_CLIENT_ID`, `CNA_NEXTAUTH_URL`, `KEY_VAULT_NAME`, `APPLICATION_INSIGHTS_NAME`, `FRONTDOOR_CERTIFICATE_NAME`, `ALZ_DIAGNOSTICS_MANAGE` | Environment wiring (several are written back by Terraform) |
| Variable | `FOUNDRY_PROJECT_ENDPOINT`, `FOUNDRY_RECOMMENDATION_AGENT_ID`, `CNA_AZURE_MCP_ENDPOINT`, `CNA_AWS_MCP_ENDPOINT`, `CNA_DRAWIO_MCP_URL` | Optional AI / MCP integrations |
| Variable | `CNA_AI_ENGINE_DEFAULT` | Tie-break engine when both BYO keys exist (`anthropic` \| `openai`); ignored in `saas` |
| Secret | `PROJECT_BOARD_TOKEN` | Optional: token `380` adds issues and PRs to the shared project board with — the core's `REVIEW.md` R-012 decides which kind; until then `380` is inert |
| Variable | `PROJECT_BOARD_URL` | Optional: the shared GitHub Project, `https://github.com/users/<owner>/projects/<n>`; unset skips `380` entirely |
| Environments | `dev`, `prod`, `hub` | `hub` carries prod's required reviewers and OIDC subject |

The core's `.env.example` is the complete inventory of every runtime variable the images read.

---

## Repository conventions

- **Four documents plus `CLAUDE.md`, one wiki.** `scripts/validate_documentation_model.py`
  enforces it in `300`. Long-form documentation lives in the core's Wiki.
- **Mirror the sibling.** Any change outside the cloud-specific table above is made in
  [`Work-Cloud_Network_AWS_Appliance`](https://github.com/saulpatinojr/Work-Cloud_Network_AWS_Appliance) in the same change set.
  Never introduce AWS content here.
- **Numbered workflows in bands** (`000` bootstrap, `100` validation, `200` deploy/update, `300`
  validate and operations). Numbers are stable across the core and both appliances — never renumber.
- **`.deployment-catalog/` is written by workflows only** (`210` records releases, `230` reads
  them). Never hand-edit it.
- **Never hardcode a value at a call site.** Regions, endpoints and account identifiers are
  declared as Terraform variables and resolved at runtime; variables a human must supply take no
  default.
- **Every GitHub Action is pinned to a SHA digest.** `detect-secrets` fails `300` on any finding not
  in `.secrets.baseline`.

---

*Maintained by Saul Patino Jr. — AWS SA Professional | Azure Solutions Architect Expert*
