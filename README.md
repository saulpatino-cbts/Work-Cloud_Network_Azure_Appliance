# Cloud Network Assessment (CNA) — Azure Appliance

[![Validate](https://github.com/saulpatino-cbts/Work-Cloud_Network_Azure_Appliance/actions/workflows/300-validate.yml/badge.svg)](https://github.com/saulpatino-cbts/Work-Cloud_Network_Azure_Appliance/actions/workflows/300-validate.yml)

This repository deploys and operates the **Cloud Network Assessment platform on Azure**.
It contains the Azure Terraform and the workflows that deploy, update, watch and tear
down an environment — and nothing else. The application itself (web, API, CLI) lives in
the **core** repository, [`Work-Cloud_Network_Core`](https://github.com/saulpatino-cbts/Work-Cloud_Network_Core),
which builds the container images this appliance runs. Features ship once, in those images; this
appliance picks them up.

Its sibling, [`Work-Cloud_Network_AWS_Appliance`](https://github.com/saulpatino-cbts/Work-Cloud_Network_AWS_Appliance), does the same
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
| `scripts/` — bootstrap and CI evidence helpers | Long-form documentation — the core's [Wiki](https://github.com/saulpatino-cbts/Work-Cloud_Network_Core/wiki) |

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

### Client installation and remediation checklist

This is the reviewable client-install runbook. All `<...>` values below are **non-secret
placeholders**, not working defaults. Replace them using the client's approved configuration
process before running anything. Do not copy the development catalog or historical subscription
names as deployment inputs. No live acceptance, repository protection, secret rotation, or
container vulnerability result is established by this document.

**Identity and ownership.** The client owns the Azure subscription, tenant, Entra sign-in
application, DNS zone, GitHub appliance repository, state backend, runtime identities and secrets.
The image publisher can remain a different organization. Set `CORE_OWNER=<upstream-owner>`,
`CORE_REPO=<upstream-core-repository>`, `DOCKERHUB_NAMESPACE=<upstream-image-namespace>` and
`IMAGE_SIGNING_IDENTITY=https://github.com/<upstream-owner>/<upstream-core-repository>/.github/workflows/200-build-images.yml@refs/heads/main`.
Use the **actual producer**, not the client's repo name, for signature trust. `230` reads that
upstream owner's repository; `210` limits its variable-management App token to the client's
appliance repository. Never weaken signature/digest checks to accommodate an unsigned mirror:
a new producer or registry needs a separately reviewed signing/provenance contract.

**Administrator preparation (not performed by this repository change).**

1. Select the client's subscription, tenant, region and non-overlapping VNet/subnet CIDRs. Review
   both platform roots' CIDR defaults before planning. Confirm service/model quota, supported
   Foundry model/version/region, data residency and recurring Firewall/Front Door/database costs.
   The deploy identity does not register providers. An authorized subscription administrator
   registers and waits for `Registered` for Microsoft.App, Microsoft.Network, Microsoft.Storage,
   Microsoft.KeyVault, Microsoft.DBforPostgreSQL, Microsoft.CognitiveServices,
   Microsoft.OperationalInsights, Microsoft.Insights, Microsoft.Cdn and Microsoft.ManagedIdentity.
   `100` checks registration read-only; `Registering` is not ready.
2. Create `dev`, `prod` and **`hub`** GitHub environments in the client's repository. Configure
   `hub` required reviewers, prevent self-review, restrict deployment branches to the client's
   protected default branch, and disable administrative bypass where supported. Verify the
   client's GitHub plan supports these protections; a YAML `environment:` alone does not create
   an approval rule. Protect workflow/Terraform changes with branch rules and human review.
3. Configure distinct client deployment identities for dev and prod using OIDC only: issuer
   `https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`, subjects
   `repo:<client-owner>/<appliance-repository>:environment:dev` and
   `repo:<client-owner>/<appliance-repository>:environment:hub`. Do not trust arbitrary branches,
   pull requests, or the upstream publisher as client deployment subjects. Store the corresponding
   `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` in each environment; production
   mutating jobs, including bootstrap, plan firewall windows, fast redeploy, drift and teardown,
   use `hub`. `prod` still owns Terraform-written runtime variables; copy approved initial
   configuration into `hub`, where production jobs resolve it. Do not rely on repository
   fallbacks containing dev identifiers.
4. Review the identities' exact permissions with the client. Steady-state deployment needs
   resource management only on its workload RG, narrowly scoped role-assignment management for
   declared runtime roles, network-watcher operations as required by the platform root, backend
   blob data access/locking, and Key Vault data access for Terraform-managed secrets. Runtime
   managed identities are distinct from CI identities. The shared runtime identity now receives
   Key Vault Secrets User only, not Secrets Officer; Terraform retains Secrets Officer on the
   deploy principal. Review/revoke any independently assigned runtime write grants during client
   rollout: removing a Terraform assignment is not evidence that all effective permissions are
   read-only. Backend creation and deletion, provider
   registration and soft-deleted AI purge need separate explicit grants at the appropriate scope.
   `330` now uses the selected environment identity throughout and fails if those rights are
   absent; it never falls back to a broader repo identity. Arrange approved temporary bootstrap/
   teardown rights or a separately reviewed operator procedure, then remove temporary grants.
   The legacy `Initialize-CnaGitHubSecrets.ps1` can create identities/roles, secrets and a local
   admin; review it before any execution. It is not a read-only installer.
5. Install the client GitHub App only on necessary repositories, with upstream Contents read
   for manifest polling and client environment-variable write permissions for Terraform.
   Keep its private key in GitHub Secrets. Prefer separate installations with narrowly scoped
   repository access; generated tokens are job-local and revoked by the action. Supply a
   pull-only Docker Hub token with access to the producer's private images. Never grant the
   deployment path registry push rights.

**Required configuration before `000` / `210`.** Set values separately for each target environment
(`dev` or production `hub`); the read-only `100` also needs its own repo-level preflight identity
and configuration. That identity should have only read permissions and an exact protected-branch
OIDC subject, not production deploy rights. `100` cannot inspect environment-scoped values;
`210` validates the actual selected environment before cloud login.

The current `100` also requires repository-scoped copies of `CNA_POSTGRES_ADMIN_PASSWORD`,
`CNA_ENTRA_CLIENT_SECRET`, `CNA_NEXTAUTH_SECRET` and `CNA_CREDENTIAL_ENCRYPTION_KEY`.
Repository scope makes these runtime secrets available to other workflows in this repository;
environment-only storage will not satisfy `100`. If that exposure is not acceptable, stop and
obtain an approved environment-scoped preflight design rather than copying production secrets.
No secret scope or protection is changed by this checklist.

The `230` updater's `detect` job also has no environment. Set `CORE_OWNER`, `CORE_REPO`,
`IMAGE_SIGNING_IDENTITY` and `DOCKERHUB_NAMESPACE` as repository variables, separately from
the target environment's deployment configuration. Scheduled/manual manifest polling needs
`GH_APP_ID` and `GH_APP_PRIVATE_KEY` at repository scope with read access to that upstream
repository. Dispatch skips polling but still needs those repository variables.

| Input | Client value / provisioning rule |
|---|---|
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (Secrets) | Client-owned nonzero UUIDs, never the all-zero example |
| `AZURE_LOCATION`, `AZURE_REGION_SHORT` (Variables) | `<client-region>`, `<short-region-code>`; code is 2-8 lowercase letters/digits |
| `TFSTATE_RESOURCE_GROUP` (Variable) | `rg-cna-<dev-or-prod>-<short-region-code>-tfstate`; roots currently require the `cna` naming convention |
| `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER` (Variables) | `<globally-unique-client-state-account>`, `<client-state-container>`; no shared example account |
| `CNA_ENTRA_CLIENT_ID`, `CNA_NEXTAUTH_URL` (Variables) | Client sign-in app UUID and `https://<client-owned-hostname>`; no trailing slash/path |
| `CNA_POSTGRES_ADMIN_PASSWORD`, `CNA_ENTRA_CLIENT_SECRET`, `CNA_NEXTAUTH_SECRET`, `CNA_CREDENTIAL_ENCRYPTION_KEY` (Secrets) | Generate through the client's secret-management process, not in this file. Encryption key must decode from base64 to exactly 32 random bytes |
| `GH_APP_ID`, `GH_APP_PRIVATE_KEY`, `DOCKERHUB_TOKEN` (Secrets) | Approved App and pull-only registry credentials; never dispatch inputs |
| `FOUNDRY_LOCATION` (Variable, `saas`) | Explicit client-approved region with quota; no inherited development-region default |
| `FOUNDRY_ACCOUNT_NAME`, `FOUNDRY_PROJECT_NAME` (Variables) | Empty derives names only for greenfield. **Upgrades must set the existing names**, including historical suffixes; a recorded SaaS deployment requires both before login, and cloud discovery refuses missing/mismatched existing account names before workload planning |
| `CNA_BYO_AI_PROVIDERS` (Variable, `byo-api`) | Explicit JSON array, e.g. `["openai"]` or `["anthropic","openai"]`, approved by client Security/data owner; no keys |
| `CNA_AI_ENGINE_DEFAULT` (Variable, `byo-api`) | One of the approved providers; invalid/missing choices fail rather than silently selecting a provider |
| `LOCAL_ADMIN_PASSWORD` (optional Secret) | Supported PBKDF2 hash only (`pbkdf2$sha256$210000$...`), never plaintext; unset means no new break-glass configuration is provisioned |

Empty values, `none`, placeholder markers, sample domains, invalid UUIDs and mismatched backend
names fail the client deployment guard. The guard checks shape/requiredness, not actual ownership,
credential validity or cryptographic randomness. Local checks use synthetic data.

**Install and deploy order.** After administrators provision approved configuration, run `000`
once for the selected environment with its explicit location, code, state RG, globally unique
state account and container. This creates/imports the workload RG and initializes the backend;
review its effects before approval. Secure the state account as secret-bearing storage: restrict
blob readers/writers, enable the client's version/backup/recovery controls, keep dev/prod state
and access separate, and record a tested recovery process. Do not download state into tickets.
Run `100` and resolve failures, then `300` local/CI gates before release. Supply all three verified
digest-pinned image references and select `ai_mode` in `210`. Platform plans/applies first;
workload is re-planned after platform exists, then applied. The production approval precedes the
apply job's fresh plan: it is **not** approval of a previously exported immutable plan. The
destructive-plan guard still runs immediately before each apply. Use a protected operator session
for detailed plan review where required; the workflow summary publishes only action counts,
not resource values or binary plans.
Existing Foundry upgrades also discover the account's project collection and require the
configured project name and full resource identity to match. Missing/mismatched project
discovery fails before planning. The project resource has Terraform `prevent_destroy`;
renaming/replacement is not a routine release and requires a separately reviewed migration.
Both apply plan guards also protect the exact indexed and historical unindexed Foundry project
addresses, including removal from configuration when its lifecycle block no longer exists.
Unrelated `azapi_resource` flow-log deletion is not blocked by this project-specific guard.
This intentionally also blocks ordinary Terraform destruction of that project; `330` uses
its separately approved resource-group deletion path. Neither guard proves live API access.

For a client hostname, the workload wires that host into Front Door using a managed certificate.
The client DNS owner must validate the domain and point it to the resulting Front Door endpoint;
certificate/domain activation is a live prerequisite, not proven by a successful Terraform
validate. Register the exact `CNA_NEXTAUTH_URL/api/auth/callback/microsoft-entra-id` redirect with the
client Entra app. A real, previously provisioned `*.azurefd.net` origin can instead be supplied
without custom-domain creation. Do not use a fictitious hostname to get past the guard.

**Credentials, BYO and recovery.** Secrets flow from GitHub Secrets through `TF_VAR_*` environment
variables into Key Vault references; Terraform state and local plans contain plaintext values
despite `sensitive` display masking. Restrict state, logs and runner access. Never enable shell
tracing, upload state/plans, or paste outputs containing values. Workflows temporarily allow a
runner IP on Key Vault/storage and remove it afterward; audit cleanup on failures/cancellation.
New vaults receive the bootstrap runner rule so initial secret creation can succeed with
default-deny. The `CnaRunnerIp` resource tag journals the exact temporary IP before existing
rules are opened; bootstrap resources carry that journal from creation. Cleanup retries three
times, verifies removal and only then deletes the journal; failure is a failed job, not a
suppressed warning. Never edit/delete the journal while its rule remains.
Every deploy/drift window first reconciles journals left by an interrupted job, including
daily dev-drift definition under its environment controls and concurrency. A read-only
Actions API check on 2026-11-04 found `350` manually disabled; no reconciliation from that
schedule can be assumed. Prod drift remains manual; there is no scheduled prod reconciliation
or guaranteed expiry. Only the owner may approve re-enabling or running these cloud-writing jobs.
A hard runner termination cannot execute cleanup or guarantee a time-bounded expiry: the rule
can remain until the next successful approved reconciliation. Clients must alert on failed/
cancelled deploy/drift runs and nonempty `CnaRunnerIp` tags, approve/retry drift promptly, or
run `bash scripts/ci/runner_firewall_window.sh cleanup` from an authorized operator checkout
with the selected environment's `TFSTATE_RESOURCE_GROUP` and scoped Azure login.
The deployment/operator identity needs resource-tag read/write access on the workload vault
and storage account for journaling; missing access fails the workflow, never broadens IAM.
This explicit command removes only journaled IP rules, preserves unrelated rules and retains
the journal on failure. Pre-existing unjournaled rules need owner inventory/removal; the script
refuses to take ownership of an already-allowed current IP. Audit both firewalls before client
traffic. Actual Azure propagation, cancellation recovery and alerting remain **NOT VERIFIED**.
`320` portal publishing also requires the owning `dev`/`prod` environment, uses `hub` for
production and shares environment concurrency with deploy/drift. It journals/reconciles only
the requested storage account, which must already exist in that environment's workload RG;
it never silently opens an account elsewhere. The same cancellation, tag-permission,
alerting and live-recovery owner gates apply. Portal publishing does not prove its separate
container-image/authentication path is production-ready.
Use client-managed expiry/rotation windows and verify Key Vault reference refresh/revision rollout.
The runtime Key Vault resources currently ignore `value` and `expiration_date` changes after
creation: editing a GitHub Secret alone does **not** rotate that existing runtime secret.
Use an owner-approved Key Vault rotation/recovery procedure and synchronize the GitHub source;
verify the active versions before the migrator or web tier consumes a changed break-glass hash.
Database-password, Entra-secret and session-secret changes need coordinated application/identity
updates; session rotation logs users out. Encryption-key rotation is **not a normal redeploy**:
changing it without a core-supported migration makes stored cloud credentials and BYO keys
unreadable. Preserve an authorized recoverable copy of the old key and matching DB backup or
schedule secure credential re-entry; rehearse recovery with the client's Security owner.
R-006's historical plan artifacts require owner deletion and coordinated rotation even after this
change; no past exposure has been removed by editing YAML.

Keep break-glass unset unless the client's Security owner approves its storage, access, recovery,
monitoring and use. Configuring a hash passes it to Terraform and the migrator; it does not resolve
the core's local-admin re-seeding/demotion policy. Removing a secret or rolling an image back is
not proof that an already-seeded account or session is revoked. Confirm revocation in the app
with the core owner before treating break-glass as disabled.

In `byo-api`, only the explicitly selected providers' exact API FQDNs are added to the platform
HTTPS egress rules. No wildcard or arbitrary hostname is accepted. API keys are entered only on
the app's AI Engine page by an authorized admin, never in Terraform, workflow inputs, repo
Variables, or this runbook. This selection configures Azure network rules only; it is not
proof that Python traffic traverses those rules. In BYO mode, both workload roots also inject
the same JSON `CNA_BYO_AI_PROVIDERS` list into web and API,
requiring `CNA_AI_ENGINE_DEFAULT` to be in that list. SaaS omits this runtime variable.
The coordinator reports that the Core allowlist reader now exists locally; it is not yet
published or verified in deployed images. Azure's local wiring is implemented, but application
enforcement in a client deployment remains **unverified**. The required contract is to reject
missing, invalid or empty BYO configuration before probing, decryption or inference and validate
each provider before use. **Cross-repository integration blocker:** require the Core commit,
passing contract tests and signed image/runtime evidence for that reader;
Azure wiring alone does not establish application enforcement. Client acceptance must separately prove the
network path and unapproved-provider denial. Do not claim end-to-end restriction before both
are verified. Coordinate key removal/active-engine selection with the core and review approved data classes,
residency, retention and provider terms. Proxy/MCP endpoints and changes to the platform base
allowlist need separate client review. In `saas`, this dedicated Azure rule adds neither public
BYO provider endpoint; that is not proof of application-level denial.

**Existing BYO upgrades:** Before deploying images with the fail-closed Core reader, set
`CNA_BYO_AI_PROVIDERS` to the client's approved nonempty JSON array in the selected deployment
environment (`hub` for production), and set `CNA_AI_ENGINE_DEFAULT` to an included provider.
Run `210` so platform network rules and both API/web revisions receive the matching policy;
`220` only changes images and cannot install this new configuration. A missing/invalid/empty
list intentionally blocks BYO in the new runtime; it must not fall back to keys already stored
in the database. Verify both revisions and Core's negative-provider tests before client traffic.
This upgrade does not change `ai_mode`, rotate keys or alter SaaS behavior.

**Publication gate.** Committing this repository is not a deployment. Merging does, however,
change the default-branch automation used by the active six-hourly `230` updater and the
daily `350` dev-drift definition (currently manually disabled per the read-only check above).
`230` can invoke a full dev release when the catalog is behind and
`AUTO_UPDATE_DEV` is not exactly `false`; drift, if approved/enabled, opens and reconciles
firewall windows even without Terraform apply. Before publishing, the owner must review those automatic effects,
required environment configuration, identities and approvals. `360` prod drift is manual.
No automation setting is changed or disabled by this checklist.

**Live acceptance and lifecycle (client-owned gates).** Before client traffic, record the exact
image digests, producer signatures/provenance and fresh core image-scan results with disposition
of remaining findings; test approved OIDC subject/branch refusal, `hub` approval and bypass
settings, login/role separation, break-glass policy, DB readiness, TLS/DNS, private endpoints,
managed-identity inference in `saas`, approved BYO provider success and unapproved-provider denial
in `byo-api`, firewall cleanup, encrypted credential handling, backup/restore and monitoring.
The offline verifier suite is not a live private-registry or runtime test.
Both supplied workload roots explicitly disable public network access on the Container Apps
environment and enable Front Door Private Link, even though web ingress is external within
that environment. Keep those paired settings; generic module defaults are not a client hardening
profile. Verify the direct `*.azurecontainerapps.io` origin is unreachable from the public
internet and Front Door remains healthy before accepting the deployment. This is NOT VERIFIED
by the local mock-provider tests.

Rollback uses verified previously signed digests through `210`, preserving the recorded AI mode;
check database migration/backward compatibility with the core first. Never flip `ai_mode` merely
to roll back an image. `220` is an approved emergency image-only change, still gated for production,
and must be reconciled with `210` afterward. `330` is destructive, not rollback: archive authorized
DB/state recovery material first, obtain the client's deletion approval and type `DESTROY`.
It waits for workload RG deletion before clearing state; locks or permissions must fail the run.
Optional backend deletion destroys recovery access, and the AI soft-delete purge is irreversible.
Keep that option off unless the approved full-reset plan includes backend deletion. Key Vault
purge protection/retention can reserve names after teardown; recover/import through an approved
operator process rather than purging, changing state, or broadening identities to bypass it.

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
   `docker.io/<namespace>/cna:<role>-sha-<7>@sha256:<digest>` — supply one per role (api, web,
   migrator). `230 · Image Update` fills them in automatically; to run `210` by hand, copy them
   from the core's `.deployment-catalog/latest-build.json` (`images.<role>` + `digests.<role>`) or
   from the `update-available` issue. Floating tags (`*-latest`, `:latest`), tag-only references,
   and empty values are refused. All `prod` deployment jobs run under `hub` and wait for its
   required reviewers.

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

- **Rollback:** `210` with `deploy_mode: rollback` and the two `previous_*_image` references
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
| Variable | `CORE_OWNER`, `CORE_REPO` | Actual upstream producer owner and core repository name; independent of the client appliance owner |
| Variable | `IMAGE_SIGNING_IDENTITY` | The core's signing identity, `https://github.com/<owner>/<core>/.github/workflows/200-build-images.yml@refs/heads/main` — `210` and `220` refuse any image whose signature and provenance do not verify against it (`100` checks it is set) |
| Variable | `DOCKERHUB_NAMESPACE` | Docker Hub namespace of the `cna` images |
| Variable | `AUTO_UPDATE_DEV` | `false` freezes dev; anything else lets `230` redeploy it |
| Variable | `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER`, `AZURE_LOCATION`, `AZURE_REGION_SHORT`, `AZURE_TARGET_SUBSCRIPTION_NAME` | Client state backend, region and optional subscription-name check |
| Variable | `CNA_ENTRA_CLIENT_ID`, `CNA_NEXTAUTH_URL`, `KEY_VAULT_NAME`, `APPLICATION_INSIGHTS_NAME`, `FRONTDOOR_CERTIFICATE_NAME`, `ALZ_DIAGNOSTICS_MANAGE` | Environment wiring (several are written back by Terraform) |
| Variable | `FOUNDRY_PROJECT_ENDPOINT`, `FOUNDRY_RECOMMENDATION_AGENT_ID`, `CNA_AZURE_MCP_ENDPOINT`, `CNA_AWS_MCP_ENDPOINT`, `CNA_DRAWIO_MCP_URL` | Optional AI / MCP integrations |
| Variable | `CNA_AI_ENGINE_DEFAULT` | Tie-break engine when both BYO keys exist (`anthropic` \| `openai`); ignored in `saas` |
| Variable | `CNA_BYO_AI_PROVIDERS`, `FOUNDRY_LOCATION`, `FOUNDRY_ACCOUNT_NAME`, `FOUNDRY_PROJECT_NAME` | Approved public BYO providers or client Foundry region/names; see client checklist |
| Secret | `LOCAL_ADMIN_PASSWORD` | Optional, owner-approved PBKDF2 break-glass hash only; see recovery limitations above |
| Secret | `PROJECT_BOARD_TOKEN` | Optional: token `380` adds issues and PRs to the shared project board with — the core's `REVIEW.md` R-012 decides which kind; until then `380` is inert |
| Variable | `PROJECT_BOARD_URL` | Optional: the shared GitHub Project, `https://github.com/users/<owner>/projects/<n>`; unset skips `380` entirely |
| Environments | `dev`, `prod`, `hub` | `hub` carries prod's required reviewers and OIDC subject |

The core's `.env.example` is the complete inventory of every runtime variable the images read.

---

## Repository conventions

- **Four documents plus `CLAUDE.md`, one wiki.** `scripts/validate_documentation_model.py`
  enforces it in `300`. Long-form documentation lives in the core's Wiki.
- **Mirror the sibling.** Any change outside the cloud-specific table above is made in
  [`Work-Cloud_Network_AWS_Appliance`](https://github.com/saulpatino-cbts/Work-Cloud_Network_AWS_Appliance) in the same change set.
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

*Maintained by CBTS.*
