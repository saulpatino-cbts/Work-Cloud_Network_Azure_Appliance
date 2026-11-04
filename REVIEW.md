# Review — human-resolvable blockers

This file tracks **only** items that an engineer cannot resolve independently. Every entry
requires external input: an approval, a credential, an account, an access grant, or a decision
that belongs to a named owner outside the engineering task itself.

Anything an engineer can solve without external input belongs in [`TODO.md`](TODO.md), not here.
Application-level blockers live in the core repository's `REVIEW.md`.

**Last reviewed:** 2026-11-04

**Local hardening update (not live proof):** README's client installation checklist and
TODO T-108 describe prepared workflow/input/egress changes. Production cloud jobs now name
`hub`, including fast redeploy, drift, AI purge and backend deletion. This does not configure
GitHub protection rules, OIDC credentials or Azure roles. R-001/R-002/R-006/R-008/R-010/R-011
remain owner-gated; the historical problem statements below are context, not assertions about
the current tenant or repository settings. In particular, no old plan artifact was deleted
and no credential was rotated.
[saulpatino-cbts/Work-Cloud_Network_Core#102](https://github.com/saulpatino-cbts/Work-Cloud_Network_Core/pull/102)
and [saulpatino-cbts/Work-Cloud_Network_AWS_Appliance#38](https://github.com/saulpatino-cbts/Work-Cloud_Network_AWS_Appliance/pull/38)
are verified merged; Azure
signed-image consumption, runtime/provider denial and final sibling parity remain unverified.
Independent re-review accepted Foundry identity and portal-journaling fixes;
the final narrowed project guard is implemented/tested but final review acceptance is pending.
The user approved the remaining merges after disclosure of the existing `230`
scheduled/dispatch dev releases and `350` scheduled firewall writes; this approval does not
authorize manual deployment or workflow enablement. `360` remains manual and still writes firewall rules.
Read-only Actions state on 2026-11-04 found `230` active and `350` manually disabled;
the daily `350` YAML is not proof of active reconciliation. No enable/disable setting was changed.
No Core release, image publication or appliance deployment is authorized by local preservation.

| ID | Blocker | Owner | Status |
|---|---|---|---|
| [R-001](#r-001--security-review-before-the-first-byo-api-deploy) | Security review of the bring-your-own AI key path and the Anthropic/OpenAI firewall egress | Security | Open — before the first `byo-api` deploy |
| [R-002](#r-002--required-reviewers-on-the-hub-environment) | `hub` environment required reviewers for prod applies | Repository admin | Open |

| [R-003](#r-003--live-azure-beta-acceptance-sign-off) | 0.8 beta exit — live Azure acceptance sign-off | Product owner | Open — deploy done 2026-08-28, acceptance outstanding |
| [R-004](#r-004--the-dev-environment-has-no-protection-against-out-of-band-deletion) | Dev environment deleted out of band; no protection against a repeat | Azure subscription owner | Open |
| [R-005](#r-005--repoint-core_repo-at-the-new-core-repository) | Verify actual upstream `CORE_OWNER`/`CORE_REPO`, App installation and signing identity | Repository admin | Open — settings not verified |
| [R-006](#r-006--rotate-secrets-that-reached-uploaded-terraform-plan-artifacts) | Inventory historical secret-bearing artifacts and coordinate deletion/rotation/recovery | Security / secret owner | Open — historical exposure not remediated here |
| [R-007](#r-007--prevent_destroy-on-stateful-resources-vs-the-330-teardown-design) | Approve stateful-resource deletion safeguards and recovery for the current RG-deletion teardown | Azure subscription owner | Open — decision |
| [R-008](#r-008--break-glass-local-admin-policy) | Local admin re-asserted as ADMIN on every deploy; no in-app off switch | Security | Open — decision |
| [R-009](#r-009--edge-and-firewall-tier-for-a-single-tenant-appliance) | Azure Firewall Premium + Front Door Premium per environment with no Premium feature in use | Azure subscription owner | Open — cost decision [VERIFY pricing] |
| [R-010](#r-010--220-fast-redeploy-to-prod-outside-the-hub-gate) | Verify effective `hub` approvals and approve the emergency Terraform/catalog bypass | Repository admin | Open — code gate implemented, live control unverified |
| [R-011](#r-011--330-purge-and-backend-destroy-jobs-run-at-repository-scope) | Verify environment-scoped teardown rights and approvals, without repo-identity fallback | Repository admin | Open — code gate implemented, live grants unverified |
---

## R-001 — Security review before the first `byo-api` deploy

**Problem**
`ai_mode: byo-api` stores admin-entered Anthropic/OpenAI API keys AES-256-GCM encrypted in the
application database and opens Azure Firewall egress to `api.anthropic.com` and `api.openai.com`.
The implementation lives in the core repository. Its allowlist implementation is merged, but Azure consumption of
its signed images and runtime behavior are not verified; human security review and actual image/network
acceptance are required before customer traffic. Azure network rules alone are not app policy.

**Required owner**
Security.

**Required action**
Complete the core repository's `REVIEW.md` → R-011 (it lists the exact files and questions), then
record the outcome here.

**Impact if unresolved**
`byo-api` cannot be offered to a customer from this appliance. `saas` is unaffected.

---

## R-002 — Required reviewers on the `hub` environment

**Read-only owner evidence (2026-11-04, coordinator):** Default branch is `main`;
branch-protection GET returned 404 "Branch not protected", and repository rulesets were empty.
Organization rulesets/permissions were not verifiable (404 / `admin:org` scope required).
This does not prove absent inherited controls or direct-push permission. The client owner must
verify effective branch and environment protections before approval; no settings changed here.

**Problem**
`210-deploy`'s prod `apply` job runs under the `hub` GitHub environment, whose required
reviewers are the human approval gate for production changes — the same gate the core used. A
freshly created repository has no environments and therefore no gate.

**Required owner**
Repository admin.

**Required action**
Create the client-owned `dev`, `prod` and `hub` environments. Configure the client's authorized
required reviewers, prevent self-review, restrict `hub` to the protected default branch and
verify that the client's GitHub plan enforces these protections. Register the prod deploy
identity's exact OIDC subject `repo:<client-owner>/<appliance-repository>:environment:hub`;
do not copy the upstream publisher's deployment identity. Provision approved client configuration
in `hub` as described in README and verify every production cloud job uses that identity.

**Impact if unresolved**
Prod deploys either fail OIDC or, worse, run without human approval.

---

## R-003 — Live Azure beta acceptance sign-off

> Transferred 2026-09-15 from the core repository's `REVIEW.md` → R-008 (core T-507).

**Problem**
The repository is at `0.8.0b0`. Code, Terraform, workflows, and the changelog are aligned on
`main`, but the beta exit gate is live Azure execution: prerequisite validation, dev deploy,
Entra redirect update, runtime validation, and customer-like beta acceptance.

**Why it blocks progress**
Acceptance is a product judgement, not an engineering result. No amount of further engineering
work moves the release posture past `0.8 beta` without someone accepting the live evidence.

**Required owner**
Product owner (with the AWS/Azure account owners for the deploy windows).

**Required action**
1. ~~Schedule the live dev deploy window (workflows 100 → 200 → 211).~~ **Done 2026-08-28** —
   though not as a scheduled window: the dev environment had been deleted out of band (see R-004
   and `the core's CNA-0.90-updates.md` §5), so it was rebuilt from nothing via `000` → `100` → `210`.
   Run `33169632082`, all jobs green.
2. **Review the deployment evidence artifacts produced by the workflow run.** These now exist:
   `.deployment-catalog/dev/33169632082.json` records `health_status: healthy`, 100% origin
   health, and passing canary, staged-promotion, certificate and private-endpoint checks.
   **Check the two Foundry markers read `passed`** — since `TODO.md` → T-104 (2026-09-23),
   `foundry_private_dns_validation` and `foundry_managed_identity_inference` are set by `210`
   itself from a probe run inside the environment, and a run cannot reach `healthy` (or the
   catalog) while either is anything else. The `33169632082` entry predates that and still
   carries them as `required`: its `healthy` verdict does not cover the AI Foundry / Copilot path,
   so accept against a `210` run made after the change.
3. Accept or reject the customer-like beta acceptance run, and record the decision.
   Note the acceptance run has not happened yet: the rebuilt environment has an empty database,
   so there is no discovery, finding, or deliverable in it to accept against.

**Impact if unresolved**
The platform stays in beta indefinitely and cannot be offered to a client engagement, regardless
of code readiness.

**References**
- `.github/workflows/100-validate-prereqs.yml`, `200-build-images.yml`,
  `210-deploy.yml`
- `scripts/ci/evaluate_deployment_evidence.py`
- [`CHANGELOG.md`](CHANGELOG.md) → `[0.8.0-beta]`

**Recommended next step**
Book the deploy window. core R-007 no longer blocks it — see that item; provider registration is now
asserted by workflow `100-validate-prereqs.yml`, which should be run first regardless.

---

---

## R-004 — The dev environment has no protection against out-of-band deletion

> Transferred 2026-09-15 from the core repository's `REVIEW.md` → R-010 (core T-507).

**Problem**
The entire Azure dev environment — workload resource group *and* the `-tfstate` resource group
holding the Terraform state — was deleted from `sub-cbtssandbox-ops-tst` around **2026-07-21**,
outside CI. No teardown workflow ran in that window (`330-teardown` last ran 2026-07-01), so the
deletion was performed directly against the subscription, consistent with a sandbox cost sweep.

It was rebuilt on 2026-08-28 (`the core's CNA-0.90-updates.md` §5), but nothing prevents a repeat, and the
rebuild was not cheap: the state loss meant a from-scratch provision, six previously-unknown gaps
in the deploy identity's least-privilege role set, a soft-deleted Key Vault to recover and import,
and roughly half a day of a pre-demo schedule.

**Why it needs an owner**
Whether the sweep is intentional policy is not an engineering question. If the sandbox is *meant*
to be swept, the environment should not be treated as durable and the demo/engagement plan has to
budget a rebuild each time. If it is not meant to be swept, the environment needs protecting. Only
the subscription owner can say which.

**Required owner**
Azure subscription owner (`sub-cbtssandbox-ops-tst`), with whoever administers the sandbox
sweep policy.

**Required action**
1. Establish whether a sweep policy exists for this subscription, what it targets, and on what
   schedule.
2. If the environment should persist: apply a `CanNotDelete` resource lock to
   `rg-cna-<env>-<region_short>` and `rg-cna-<env>-<region_short>-tfstate` at minimum — the state RG especially, since
   losing it is what turned a redeploy into a rebuild — or request an exclusion from the sweep.
3. If the environment is legitimately ephemeral: record that in the demo/engagement runbook so a
   rebuild is planned rather than discovered, and consider whether the tfstate backend should live
   in a subscription that is not swept.

**Impact if unresolved**
The next sweep repeats the same half-day recovery, at whatever moment it happens to land. The
permission gaps are now codified in `scripts/Initialize-CnaGitHubSecrets.ps1`, so a second rebuild
would be materially faster — but it would still be a rebuild, with a fresh, empty database.

**References**
- [`the core's CNA-0.90-updates.md`](the core's CNA-0.90-updates.md) → §5 (the full rebuild record)
- [`TODO.md`](TODO.md) → T-105 (the drift check that detected this and told no one)
- `.deployment-catalog/dev/33169632082.json` (the rebuild's evidence)

**Recommended next step**
Ask the sandbox administrator the one question that decides everything else: is
`sub-cbtssandbox-ops-tst` swept on a schedule, and can these two resource groups be excluded?

---

---

## R-005 — Repoint `CORE_REPO` at the new core repository

**Problem**
The core moved from `Work-Cloud_Network_Assessment` to `Work-Cloud_Network_Core` (core `TODO.md`
T-509). `230-image-update` reads the build manifest from the repository named by the `CORE_REPO`
variable through the GitHub App; if the variable still names the original repository, this
appliance keeps polling a manifest that will never change again, and the dispatch from the new
core's `200-build-images` reaches this repository only if the App is installed on the new core.

**Why it needs an owner**
Repository variables and GitHub App installations are settings only the repository admin can write.

**Required owner**
Repository admin.

**Required action**
1. Verify the actual producer repository and App installation rather than assume the migration
   or permissions are incomplete. This session did not inspect the current configuration.
2. Verify `CORE_OWNER`, `CORE_REPO` and `IMAGE_SIGNING_IDENTITY` identify the same approved
   producer. Any settings change or Core image release requires separate owner approval.
3. Before any approved `230` run, review its possible dev apply and prod issue effects.
   A scheduled/dispatch update is not a read-only manifest check.
4. Do the same in the sibling appliance.

**Impact if unresolved**
No new image set ever reaches this appliance: `dev` stops auto-updating and no `update-available`
issue is opened for `prod`. After the original repository is deleted, every `230` run fails outright.

**References**
- `.github/workflows/230-image-update.yml` (`vars.CORE_REPO`)
- `README.md` → *Configuration*
- Core `REVIEW.md` R-013 / `TODO.md` T-509

---

## R-006 — Rotate secrets that reached uploaded Terraform plan artifacts

**Problem**
Until 2026-09-23 `210-deploy` uploaded the workload `tfplan-*` file as a run artifact with the
default 90-day retention. A saved plan stores every variable value in plaintext — `sensitive`
only redacts CLI output — so the artifact carried `CNA_POSTGRES_ADMIN_PASSWORD`,
`CNA_ENTRA_CLIENT_SECRET`, `CNA_NEXTAUTH_SECRET` and `CNA_CREDENTIAL_ENCRYPTION_KEY` for anyone
with read access to the repository. The upload is removed; historical deletion, current retention and exposure are not verified here.

**Required owner**
Security / secret owner.

**Required action**
Delete every `tfplan-*` artifact under **Actions → run → Artifacts** for past `210` runs, then
rotate the four secrets. Rotating `CNA_CREDENTIAL_ENCRYPTION_KEY` makes every stored cloud
credential and BYO AI key undecryptable (core `TODO.md` → T-707), so schedule the re-entry of
those credentials with the rotation.

**Impact if unresolved**
Repository readers can recover the dev environment's runtime secrets from old artifacts.

**References**
- v1.0 review finding DEVOPS-002

## R-007 — `prevent_destroy` on stateful resources vs. the `330` teardown design

**Problem**
The release plan guard protects selected stateful types and exact Foundry project addresses;
the Foundry project additionally has `prevent_destroy`. `330` currently deletes the workload
resource group directly, waits for deletion, then clears workload state; Terraform lifecycle
guards do not protect against that Azure RG deletion. Locks, deletion grants and recoverable
backups therefore need explicit owner acceptance.

**Required owner**
Azure subscription owner.

**Required action**
Approve resource locks/deletion rights and backup/restore requirements for `330`; verify
Foundry project ownership before migration or deletion. Do not treat `prevent_destroy` as
protection against direct Azure deletion or bypass a lock to make teardown pass.

**Impact if unresolved**
An out-of-band or misdirected apply can delete customer data with no Terraform-level stop.

**References**
- v1.0 review finding DEVOPS-AZ-001; R-004

## R-008 — Break-glass local admin policy

**Problem**
The migrator runs `seed-local-admin.js` on every deploy and upserts `local-admin@cna.local`
with `role: ADMIN`; demoting or deleting the account is reverted at the next deploy, the only off
switch is unsetting `CNA_LOCAL_ADMIN_PASSWORD`, the limiter on `/api/local-admin` is per replica
and keyed on `x-azure-clientip`, and the break-glass account exists on Azure only.

**Required owner**
Security.

**Required action**
Choose: keep and document the off switch; seed only on the first deploy (`LOCAL_ADMIN_SEED`
flag); or remove in favour of Entra-only administration.

**Impact if unresolved**
A standing administrative account that cannot be durably disabled from the product.

**References**
- v1.0 review findings DATA-005, IMG-017, SEC-004, ARCH-107

## R-009 — Edge and firewall tier for a single-tenant appliance

**Problem**
Each environment runs Azure Firewall **Premium** and Front Door **Premium** with no Premium
feature configured (no IDPS, no TLS inspection). The lean-architecture review estimates roughly
$1.3k/month for the firewall and $330/month for Front Door per environment — several times the
compute and database cost [VERIFY against subscription rates].

**Required owner**
Azure subscription owner.

**Required action**
Decide between Standard tiers (Front Door Standard keeps WAF + Private Link is Premium-only —
weigh against the origin lock), a NAT Gateway in place of the firewall for egress, or keeping
Premium with a stated reason.

**Impact if unresolved**
Cost; no security impact either way.

**References**
- v1.0 review findings NET-007, ARCH-111

## R-010 — `220-fast-redeploy` to prod outside the `hub` gate

**Problem**
Historically `220` used `prod` rather than `hub`. The current implementation selects `hub`
for prod, validates the target and verifies digest-pinned images. It still bypasses Terraform
and the release catalog; actual reviewers, branch restrictions and OIDC rights are unverified.

**Required owner**
Repository admin.

**Required action**
Verify effective `hub` controls and scoped OIDC rights, approve emergency operator access,
and require a subsequent `210` release to reconcile Terraform and the catalog.

**Impact if unresolved**
A single operator can put an arbitrary image into production with no second pair of eyes.

**References**
- v1.0 review finding DEVOPS-AZ-003

## R-011 — `330` purge and backend-destroy jobs run at repository scope

**Problem**
Historically purge/backend deletion used a repository identity. Every current `330` production
job now selects `hub` and uses environment-scoped identity; no broader repo-identity fallback
is used. Actual permissions for subscription-level AI purge and backend RG deletion, and
effective reviewer/branch controls, remain unverified. Missing rights must fail the run.

**Required owner**
Repository admin.

**Required action**
Review each teardown target and approve narrowly scoped temporary rights or an operator
procedure. Verify all jobs use the intended environment subject; do not broaden steady-state
deploy rights just to permit purge or backend deletion.

**Impact if unresolved**
Teardown may fail safely for missing rights, or be overprivileged without effective owner
controls. Code-level environment selection is not evidence of protected GitHub settings.

**References**
- v1.0 review finding DEVOPS-005; WS-4 verification note

## R-012 — Image signature verification: set the identity and roll out in order

**Problem**
`210` and `220` now refuse any image whose cosign signature and SLSA provenance do not verify
against the repository variable `IMAGE_SIGNING_IDENTITY` (core `TODO.md` → T-703). Two things
only a human can do: choose and set that identity, and sequence the roll-out. The identity is the
core's `200-build-images` workflow subject —
`https://github.com/<owner>/<core>/.github/workflows/200-build-images.yml@refs/heads/main` — and it
changes whenever the core repository is renamed or moved (it moved once already, in 2026-09),
the workflow file is renamed, or the default branch changes. Images the core built before its
T-703 change carry no signature; that includes every rollback target recorded in
`.deployment-catalog/` so far.

**Required owner**
Repository admin.

**Required action**
1. Merge the core's T-703 change first and let `200-build-images` publish one signed image set.
2. Set `IMAGE_SIGNING_IDENTITY` to the core workflow subject above, with the core's **current**
   owner and repository name; run `100-validate-prereqs`.
3. Merge this change in both appliances. The first `210` after that must deploy the signed set;
   a rollback to a pre-T-703 digest fails verification by design — roll forward instead.
4. When the core is renamed or moved again, update the variable in both appliances before the
   next deploy.

**Impact if unresolved**
With the variable unset, every `210` plan and every `220` run fails at the verification step
(fail closed; nothing deploys). With a stale identity, the same.

**References**
- v1.0 review findings RELEASE-003, IMG-012; core `TODO.md` → T-703
