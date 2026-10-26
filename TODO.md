# TODO — engineering work queue

The authoritative engineering backlog for the Azure appliance. Application work belongs
in the core repository's `TODO.md`; this file covers deployment, operations and this repository.

Items requiring external input — an approval, an account, a credential, an access grant — belong
in [`REVIEW.md`](REVIEW.md), not here. Completed work is recorded in [`CHANGELOG.md`](CHANGELOG.md).

**Last reviewed:** 2026-09-15

| Phase | Theme | Items |
|---|---|---|
| [Phase 1](#phase-1--bring-up) | Bring-up | T-101 – T-106 |

---

## Phase 1 — Bring-up

### T-101 — Verify the first `saas` apply is a pure re-addressing

- **Priority:** High
- **Description:** The import from the core added `count` to the AI module, the four Foundry role
  assignments and the Foundry private endpoint, each with a `moved` block. On an environment that
  already exists (dev), the first `210-deploy` plan must show only those `moved` annotations plus
  three in-place Container App env updates (`CNA_AI_MODE`, `CNA_APPLIANCE_CLOUD`,
  `CNA_AI_ENGINE_DEFAULT`) — no create, no destroy.
- **Recommended action:** Run `210-deploy` for dev in `saas` mode, stop at the plan artifact, and
  read it line by line before approving. A destroy of `module.ai` means a `moved` block is missing.
- **Status:** Static half done (2026-09-23); the live plan read is still owed and is the only
  step left. Dev was last applied from core commit `3245c254` (release catalog `33169632082`).
  Against that commit: every resource that gained `count` — `module.ai`, the four
  `azurerm_role_assignment.*_foundry_user`, `module.security.azurerm_private_endpoint.foundry` —
  has a `moved` block to its `[0]` address (six in total, the private endpoint's inside the
  security module), and the resource inventory of the workload root and all eight modules is
  otherwise **identical**, so nothing can legitimately be created or destroyed. The platform plan
  must be empty (only the module source paths changed). The workload plan must show exactly:
  the six `moved` annotations; in-place env updates on `ca-api` and `ca-worker` adding
  `CNA_AI_MODE`, `CNA_APPLIANCE_CLOUD`, `CNA_AI_ENGINE_DEFAULT`; on `ca-web` adding
  `CNA_AI_MODE`, `CNA_APPLIANCE_CLOUD`, `CNA_WEB_IMAGE`, `CNA_IMAGE_REGISTRY_USERNAME`,
  `CNA_APPLIANCE_REPO` and the secret-backed `CNA_IMAGE_REGISTRY_TOKEN` (from the existing
  `container-registry-password` secret — no new secret); the image references, if the build
  manifest has moved on; `cna-api` additionally gains `CREDENTIAL_ENCRYPTION_KEY` only in
  `byo-api`, so nothing in `saas`; and possibly an in-place `network_rules` update on the storage
  account, whose `Deny` default and `AzureServices` bypass are now declared in the module (its
  `ip_rules` are ignored). Anything else — any `create`, any `destroy`, any `replace` — is a
  finding. The destroy half is now enforced, not just read: `210`'s apply job refuses a plan that
  would delete or replace the Foundry account or its model deployment (and the storage account),
  on top of the T-103 log-store and database guard, so a missing `moved` block can no longer reach
  `apply`. Close this item when the first `210` dev run after these merges shows the plan above.

### T-102 — Add this repository to the shared project board

- **Priority:** Low
- **Description:** `230-image-update`'s `update-available` issues should land on the one project
  board shared with the core and the sibling appliance.
- **Dependencies:** The core repository's `REVIEW.md` → R-012 (token decision).
- **Recommended action:** Add a SHA-pinned `actions/add-to-project` workflow on `issues: opened` and
  `pull_request: opened`, identical in both appliances.
- **Status:** Done (2026-09-23) as far as this repository can go — `380 · Project Board` is
  authored and inert. It runs on `issues: opened|reopened` and
  `pull_request: opened|reopened|ready_for_review`, is skipped while the `PROJECT_BOARD_URL`
  variable is unset, and exits with a notice while the `PROJECT_BOARD_TOKEN` secret is unset;
  once the core's R-012 is decided, setting the two turns it on with no further change. It uses
  `gh project item-add` rather than the recommended `actions/add-to-project`: nothing to
  SHA-pin, and the R-012 token is the only moving part either way. Identical in the AWS appliance (its T-103);
  the core's own copy is its T-505 (its `CLAUDE.md` reserves workflow numbers, so `380` is
  recorded there when the core adopts it).

### T-103 — Log Analytics workspace state migration, for already-deployed Azure environments only

- **Origin:** core `TODO.md` → T-304, transferred 2026-09-15 (core T-507).
- **Priority:** Low
- **Description:** The Log Analytics workspace (`<name_prefix>-log`) moved from the `compute`
  module (workload state) to the platform landing zone, removing a cross-state dependency. The
  code change is done, but in an environment that was already deployed the resource still
  physically lives in workload state. Applying without migrating state first makes workload want
  to **destroy** the workspace and platform want to **create** it — which deletes all historical
  log data.
- **Dependencies:** Only applies to an environment already deployed with the old layout. As of the
  last check no environment was deployed, so this is a no-op for the initial rollout.
- **Recommended action:** Follow the runbook below before the next apply in any affected
  environment. Run it **once per environment** (dev, then prod).
- **Status:** Done (2026-09-23) — **not applicable to any existing environment, verified.** The
  move landed in the core on 2026-06-28 (core commit `756fb529`, "move Log Analytics workspace to
  platform"). The only deployed environment, dev, was rebuilt from nothing on 2026-08-28 (release
  catalog `33169632082.json`, core commit `3245c254`), and at that commit the platform root already
  declared `azurerm_log_analytics_workspace.platform` while the workload root read it through
  `data.azurerm_log_analytics_workspace.platform` — so dev's workspace has lived in platform state
  from its first apply. Prod has never been deployed. No state migration is pending anywhere; the
  runbook below is kept for an environment that might one day be restored from a pre-2026-06-28
  state backup. Its step 4 ("stop if the workload plan wants to destroy the workspace") is now
  automatic: `210`'s apply job refuses, right before each apply, any platform or workload plan
  that would delete or replace the Log Analytics workspace or the PostgreSQL server
  (`scripts/ci/refuse_destructive_plan.py`, `PROTECTED_RESOURCE_TYPES`). Mirrored in the AWS
  appliance for CloudWatch log groups and the RDS instance.
- **Notes for future engineers:**

  **Why the workspace moved.** The workspace used to be created by the `compute` module, which
  lives in workload state. It moved to the platform landing zone so that platform-owned resources
  (firewall, NSGs, VNet flow logs) send diagnostics to a workspace in the same state that creates
  them, removing the cross-state dependency. The code change is done; in an already-deployed
  environment the resource still physically sits in workload state.

  **Preconditions**
  - Azure CLI authenticated with rights to the tfstate storage account.
  - `terraform` 1.14.x on PATH.
  - Both roots initialized against their real backends. The deploy pipeline does this; locally,
    `terraform init -backend-config=...` with the same keys the workflow uses — see
    `210-deploy.yml`.
  - **Take a state backup first.**

  **State addresses**

  | | Address |
  |---|---|
  | Source (workload state) | `module.compute.azurerm_log_analytics_workspace.compute` |
  | Destination (platform state) | `azurerm_log_analytics_workspace.platform` |

  The Azure resource ID is unchanged — only which state file tracks it changes:
  `/subscriptions/<SUB>/resourceGroups/rg-<name_prefix>/providers/Microsoft.OperationalInsights/workspaces/<name_prefix>-log`

  **Procedure.** Replace `<env>` with `dev` or `prod`. Backend keys mirror the deploy workflow:
  platform = `<env>.terraform.tfstate`, workload = `<env>.workload.terraform.tfstate`.

  1. Back up both states:
     ```bash
     cd infra/terraform/environments/<env>/workload
     terraform state pull > /tmp/backup-workload-<env>.tfstate
     cd ../platform
     terraform state pull > /tmp/backup-platform-<env>.tfstate
     ```
  2. Remove the workspace from workload state — do **not** destroy. `state rm` forgets the
     resource in Terraform without touching Azure; the workspace keeps running and retains its
     data:
     ```bash
     cd infra/terraform/environments/<env>/workload
     terraform state rm 'module.compute.azurerm_log_analytics_workspace.compute'
     ```
  3. Import the existing workspace into platform state. `name_prefix` = `cna-<env>-<region_short>`; get
     `<SUB>` from `az account show --query id -o tsv`:
     ```bash
     cd ../platform
     terraform import 'azurerm_log_analytics_workspace.platform' \
       "/subscriptions/<SUB>/resourceGroups/rg-<name_prefix>/providers/Microsoft.OperationalInsights/workspaces/<name_prefix>-log"
     ```
  4. Verify both plans are clean:
     ```bash
     cd ../platform && terraform plan    # workspace: NO changes. It WILL want to CREATE the new
                                         # flow-logs storage account + observability diagnostic
                                         # settings — expected and correct.
     cd ../workload && terraform plan    # NO destroy of the workspace. compute env now reads it
                                         # via data source; observability is app-only.
     ```
     **Stop and investigate if the platform plan wants to _create_ the workspace, or the workload
     plan wants to _destroy_ it** — that means the `rm`/`import` did not take.
  5. Apply platform first, then workload. Platform must apply before workload so the workspace and
     its outputs exist for the workload's `data.azurerm_log_analytics_workspace.platform` lookup.
     This matches the deploy order in `210-deploy.yml`.

  **Also worth knowing**
  - The dedicated flow-logs storage account (`<name_prefix>flowlog`) and the firewall/NSG/flow-log
    diagnostic settings are **new** platform resources — no migration needed, they appear on the
    first platform apply.
  - Retention is 30 days in `platform/locals.tf` for both environments, reduced from prod's
    previous 90 during the FinOps pass. Reviewed and approved.
  - If you would rather not do state surgery, the alternative is accepting a one-time workspace
    recreation and the loss of log history. Not recommended for prod.

### T-104 — Nothing ever validates the AI Foundry path, and the deploy manifest says so out loud

- **Origin:** core `TODO.md` → T-415, transferred 2026-09-15 (core T-507).
- **Priority:** High
- **Category:** Deployment verification
- **Description:** `210-deploy.yml` writes the deployment manifest with
  `"foundry_private_dns_validation": "required"` and
  `"foundry_managed_identity_inference": "required"` as **hardcoded literals** (workflow lines
  ~572–573). Every other check in that block starts `"pending"` and is flipped to `"passed"` by a
  later step; these two are never flipped by anything, because no step exists that would. They are
  markers meaning "a human must confirm this out of band" — but nothing in the workflow, the
  evidence evaluator, or the demo checklist says who, and a green `210` run therefore reports
  `health_status: healthy` on an environment whose Copilot path has never been exercised.
  This is not hypothetical: the 2026-08-28 rebuild (`the core's CNA-0.90-updates.md` §5) produced exactly
  that — a fully green deployment with both markers still `required`.
- **Dependencies:** A deployed environment (dev now qualifies).
- **Recommended action:** Decide which the two markers are and act accordingly.
  1. **If they are automatable** — resolve the Foundry private DNS record from inside the
     Container Apps environment and make one managed-identity inference call — then add a step
     that does it and flips both to `passed`/`failed`. That is the honest fix: the check becomes
     real and `healthy` starts meaning something.
  2. **If they genuinely need a human** (e.g. model-deployment capacity judgement), then the
     manifest should not present them alongside machine checks. Move them to a named
     `manual_verification` block, and make `evaluate_deployment_evidence.py` refuse to report a
     deployment as fully verified while any manual item is outstanding.
  Either way, add the check to the demo/release checklist explicitly rather than leaving it in a
  JSON field nobody reads.
- **Notes for future engineers:** `the core's CNA-0.90-updates.md` §2.3 already flagged the Foundry path as
  "the least-proven infra" for unrelated reasons (the dev account was renamed `-aif2` after a
  soft-delete collision). Two independent signals pointing at the same untested path is the
  argument for closing this one properly rather than deleting the markers.
- **Status:** Done (2026-09-23) — option 1, the markers are automatable. `210`'s apply job gains
  "Verify the AI Foundry path from inside the environment" (`saas` only): a one-off Container Apps
  Job in the same environment, with the same user-assigned identity and the same api image as
  `cna-api`, runs `scripts/ci/probe_foundry_path.py`, which resolves the Foundry host from inside
  the VNet (the answer must fall in the private-endpoint subnet) and makes one managed-identity
  chat completion against the deployment the api is configured with — the exact call path the
  `azure-openai` engine uses. The two verdicts reach the manifest through
  `update_apply_evidence.py` (`AI_PATH_CHECKS`), and `evaluate_deployment_evidence.py` now refuses
  to report `healthy` while *any* validation check is not `passed` / `not_applicable` — `required`,
  `pending`, `failed` and `unverified` all block, so the manifest can never again say healthy about
  a path nobody exercised. The checklist item in `REVIEW.md` → the acceptance run now reads the
  two markers as machine results. Shared parts (the two evidence scripts) and the AWS twin (the
  `bedrock_*` markers, verified by a one-off Fargate task) landed in the sibling in the same change
  set. Not yet exercised against the live dev environment: the first `210` run after merge is the
  proof, and if it fails, the manifest will say so instead of `healthy`.

### T-105 — A scheduled drift check failed daily for five weeks and nothing surfaced it

- **Origin:** core `TODO.md` → T-416, transferred 2026-09-15 (core T-507).
- **Priority:** High
- **Category:** Operational safety
- **Description:** `350-drift-dev.yml` runs on a schedule and failed **every day from 2026-07-21
  to 2026-08-28** with `ResourceGroupNotFound: rg-cna-<env>-<region_short>-tfstate`. That failure was the
  first and clearest evidence that the dev environment had been deleted out of band, including its
  Terraform state backend — the single fact that would have changed the plan for the 0.9.0 demo
  work, five weeks before anyone discovered it by trying to deploy (`the core's CNA-0.90-updates.md` §5).
  The workflow did its job perfectly. The gap is that a failing scheduled run notifies nobody:
  GitHub emails the *workflow author* on scheduled-run failure, which for a bot-authored workflow
  reaches no one who acts on it.
- **Dependencies:** None.
- **Recommended action:** Give scheduled-check failures a destination. The cheapest version that
  actually works: on failure, `350-drift-dev` and `360-drift-prod` open (or update) a GitHub
  issue with a fixed title — deduplicating by title so five weeks of failures is one issue that
  gets staler and more visible, not 35 notifications. Assign it to the repository owner. Consider
  the same treatment for `370-registry-cleanup` and any other unattended schedule.
  A second, independent guard is worth its keep given what happened: have the drift workflow
  distinguish "resources drifted" from "the environment does not exist", and treat the second as
  a distinct, louder failure — those mean very different things.
- **Notes for future engineers:** Do not close this by muting the check or by making it tolerate
  a missing backend. The check was right; the delivery was missing.
- **Status:** Done (2026-09-23). `350`/`360` each gain a `report-failure` job that runs when the
  drift job fails and opens a GitHub issue — deduplicated by exact title, so a month of daily
  failures is one issue with one comment per further failure, assigned to the repository owner
  (unassigned if the owner is an organization, rather than not opened) — and the platform
  `terraform init` step classifies the failure: a missing state backend or an empty state is
  reported as **"the environment does not exist"**, its own title and message, distinct from
  "the drift check failed" (init/plan error, expired credential, provider fault). Drift itself
  stays a run warning, never an issue. The plan step also fails on a plan *error* instead of
  reading it as "no drift". `370-registry-cleanup` is the core's workflow and the core's call.
  Mirrored in the AWS appliance in the same change set.

### T-106 — Terraform findings imported from the core's production-readiness review

- **Priority:** Medium
- **Origin:** the core repository's review engine (`cna/review/areas/terraform_azure*.py`), exported 2026-09-15 when the deployment layer left the core (core T-504/T-508). Paths are rebased to this repository's layout.
- **Description:** One entry per recorded finding, in the engine's own words. `INFORMATIONAL` entries are verified-compliant outcomes — kept so the record shows what was checked, not only what was found. Escalations name the `REVIEW.md` blocker that owns them.
- **Recommended action:** Work the MEDIUM/HIGH entries; keep the verified-compliant ones true when the modules change.
- **Status:** Done for everything engineering can do (2026-09-23). The one HIGH is the product
  owner's live acceptance sign-off (`REVIEW.md` R-003) and stays there. The MEDIUM (storage account
  deny-by-default network rules) is confirmed in the tree: `modules/storage/main.tf` declares
  `network_rules { default_action = "Deny", bypass = ["AzureServices"], ip_rules = var.bootstrap_ip_rules }`
  with `ignore_changes = [network_rules[0].ip_rules]`, and `210`/`350`/`360` open and close the
  transient runner IP around every Terraform run. The LOW (dev's `-aif2` Foundry account name and
  re-declared `gpt-chat-latest` deployment) is a live-state fact that reconciles only when the
  soft-deleted `cna-dev-eus2-aif` account is purged; it is observed by `350` (which now opens an
  issue when it fails) and is recorded, not applied. Both INFORMATIONAL sweeps re-run clean today:
  `terraform fmt -check -recursive` and `terraform init -backend=false && terraform validate` on
  all four roots (Terraform 1.16.3); `300 · Validate` runs the same sweep on every push, so a
  regression cannot land silently. Each entry below carries its outcome in *italics*.

**Findings**

- **HIGH** `infra/terraform/environments/azure` (`terraform-azure:gated:live-acceptance-sign-off`) — Live Azure beta-exit acceptance sign-off (REVIEW.md R-003) is required before the 0.8 beta can exit: a product owner must validate the deployed Azure environment against the live subscription and sign off. This is a human-gated decision that cannot be performed by engineering — escalate; do not attempt a live apply or any automated live acceptance (escalation-only). *Escalation — owner: this repository's `REVIEW.md` → R-003.* *Still the owner's; the evidence it needs is now stronger — a `210` run cannot reach `healthy` while the AI Foundry path is unverified (T-104).*
- **MEDIUM** `infra/terraform/modules/storage/main.tf::azurerm_storage_account.this` (`terraform-azure:storage-account-network-rules-deny-default`) — Add a deny-by-default network_rules block (default_action = "Deny", bypass = ["AzureServices"]) to the application storage account so it is no longer reachable from arbitrary internet source IPs. Application traffic uses the private endpoint created in the security module; keep public_network_access_enabled = true for the Terraform/static-website bootstrap window and ignore_changes on network_rules[0].ip_rules so the deploy/drift workflows can add and remove the transient runner IP without perpetual drift — mirroring the Key Vault (identity module) and the flow-log storage account (platform root). Applied in this task. *Confirmed in the tree 2026-09-23; see Status.*
- **LOW** `infra/terraform/environments/dev/workload/main.tf::module.ai` (`terraform-azure:dev-environment-live-drift`) — Record drift of the live-but-stale Azure dev environment from the current Terraform definition. The code carries dev-only workarounds pinned to live-state facts — the AI Foundry account name bumped to '-aif2' to sidestep the soft-delete graveyard of the reserved '-aif' name, and the gpt-chat-latest deployment re-declared in Terraform after it was lost with that name bump. Reconcile once the soft-deleted '-aif' account is purged or its retention lapses (revert the account name to 'cna-dev-eus2-aif'). Live reconciliation runs through the 350-drift-dev.yml workflow against the live subscription (human-observed); it is recorded here, not auto-applied. *Still live-gated; `350` now reports a failing check as an issue (T-105) so the drift is not silent. Revert the name to `cna-dev-eus2-aif` only after the soft-deleted account is purged — the workload variable `azure_openai_endpoint` default carries the same suffix and must change with it.*
- **INFORMATIONAL** `infra/terraform/environments/azure` (`terraform-azure:terraform-validate-sweep`) — Verified compliant: terraform fmt -check is clean (recursive) across the Azure provider modules and environment roots, and terraform init -backend=false + terraform validate succeed for every Azure environment root (infra/terraform/environments/dev/platform, infra/terraform/environments/dev/workload, infra/terraform/environments/prod/platform, infra/terraform/environments/prod/workload) on Terraform v1.15.8. init uses -backend=false so no live azurerm state backend is contacted; no terraform apply is run. Re-run this validate sweep on every evaluation of the Azure Terraform (Requirement 3.2) and guard against a validate regression. *Re-run clean 2026-09-23 on Terraform 1.16.3; `300 · Validate` enforces it on every push.*
- **INFORMATIONAL** `infra/terraform/providers/azure` (`terraform-azure:best-practice-baseline-verified`) — Verified compliant: tags thread through every module (local.tags in the roots; var.tags plus local.foundry_tags in ai); diagnostic settings cover every app-plane target via the observability module plus platform firewall/NSG/flow-log coverage; SKU tiers are production-appropriate (Front Door Premium, firewall Premium, PostgreSQL GP with geo-redundant backup, Key Vault standard for secret storage); and network exposure is private-endpoint / delegated-subnet based with deny-by-default NSGs. terraform fmt is clean across all eight modules and both environments. Guard against regression. *Still true 2026-09-23; the storage account now also carries deny-by-default network rules, and the platform's `210` guard refuses any plan that destroys the log store, the database, the storage account or the Foundry account.*
