# CR-002: Environments as configuration, deploys by scope, and entitlements kept apart

| | |
|---|---|
| Repository | `anilvenugopal/piq-databricks-platform` |
| Author | Anil Venugopal |
| Date | 23 October 2026 |
| Status | Implemented on branch `refactor/scoped-deploys`; checked by tests that need no cloud access; **not yet applied to real cloud** |
| Builds on | CR-001 (federated domains and CI/CD) |

---

## 1. Objective

1. **Environments are configuration.** dev and prd must not be written into code. A new environment (qa, uat, a second dev) is a config entry. The prod environment has stricter rules than the others, and the rules follow the environment's *tier*, not its name.
2. **Deploy one thing at a time.** A change for one domain is deployed to dev, then to prd on demand, **without touching any other domain or environment**. Each environment has its own pipeline, identity and approval.
3. **Promote by release.** Several dev deploys can happen before one prod release. Prod accepts a tagged release that has already succeeded in the earlier environments. Hotfixes are possible, with an approver.
4. **Keep people-to-group decisions apart from infrastructure.** What an identity-governance tool (SailPoint, Saviynt, PingID) would own must be separable now, even though no such tool exists yet.
5. **Let domains differ inside a common structure.** A domain may add schemas, roles and personas of its own; platform and governance still decide what they may do.

---

## 2. Summary of changes

| ID | Change | Depends on |
|---|---|---|
| C-1 | Environment tiers and the promotion graph in `config/platform.yaml` | none |
| C-2 | Scopes and one Terraform state per scope | C-1 |
| C-3 | Wrappers: scoped plan, apply and check; scope check; promotion gate; releases; deploy records | C-2 |
| C-4 | Pipelines: `deploy.yml`, `release.yml`, `plan.yml`, `drift.yml` | C-3 |
| C-5 | One Terraform identity and one resource group per environment | C-1 |
| C-6 | Entitlements folder and stack `25-access` | C-2 |
| C-7 | Personas per environment | C-1, C-6 |
| C-8 | Domain shape and domain access files | C-2, C-7 |
| C-9 | Tests | all |
| C-10 | Documentation | all |

---

## 3. Before you start: tear down and rebuild the environments

This platform has no real data and no real users, so the environments are rebuilt instead of migrated. Terraform state keys change (`<stack>.tfstate` becomes `<stack>/<env>/<scope>.tfstate`), so the **old** stacks must be destroyed with the **old** code, before the new code is applied.

You keep: the Databricks account, `bootstrap/`, and the state storage account `rg-piq-tfstate`.

### 3.1 Destroy with the old code

Run from `main` (the code before this change), in reverse order:

```bash
git switch main
for s in 70-observability 60-governance 55-ai-platform 50-workspace 40-unity-catalog 30-account 20-identity 10-foundation; do
  ./scripts/tf.sh $s init -input=false && ./scripts/tf.sh $s destroy
done
```

Read each destroy plan before you accept it. Do not destroy `bootstrap/`.

### 3.2 Things that catch people out

| Item | What happens | What to do |
|---|---|---|
| Key Vault names | A destroyed Key Vault stays reserved. The old code turns on purge protection for `prd` (90 days) and allows purging `dev` (7 days) | Change `unique_suffix` in `config/platform.yaml` (currently `av30`) before rebuilding. Storage account names are freed immediately |
| Entra groups and service principals | Recreated with new object IDs | Refresh every GitHub variable that held an ID |
| Old state files | `<stack>.tfstate` blobs stay in the `tfstate` container | Delete them after the destroy: list blobs with no `/` in the name (`az storage blob list --container-name tfstate --account-name <state account> --auth-mode login --query "[?!contains(name,'/')].name"`) and delete those |
| Metastore | It lives at account level and survives | In the account console, confirm the metastore is attached to the new workspaces, and set `piq-metastore-admins` (a new group) as metastore admin again |
| Resource groups | The old stack 10 created `rg-piq-<env>`; bootstrap now creates them | Destroying stack 10 first removes them, so bootstrap can recreate them. Skipping the destroy makes bootstrap fail with "already exists" |

### 3.3 Rebuild order

1. On the new code, re-run `bootstrap/` (`terraform apply`). It creates the per-environment resource groups and identities.
2. Create the GitHub environments and variables printed by `terraform output next_steps` and `github_variables`.
3. Deploy in the order of section 8.

---

## 4. Decisions resolved

| ID | Decision | Resolution |
|---|---|---|
| D1 | After a merge, does dev deploy automatically? | **No.** Dispatch only (ADR-029). A merge changes nothing by itself |
| D2 | Move people and approvals into their own stack now or later? | **Now** (C-6, ADR-025) |
| D3 | Which environments now? | **dev and prd**, but configuration-driven so more are config only (C-1, ADR-023) |
| D4 | Branching | `main` only, release tags, no environment branches (ADR-024, ADR-028) |
| D5 | One Azure subscription or two? | **One for now.** A per-environment subscription is *not* implemented; it would need a config field and the provider settings per environment |

---

## 5. Changes

### C-1. Environment tiers and the promotion graph

**Objective.** The environment list and its rules are configuration. Adding qa is a config entry.

**Finding.** "dev" and "prd" were written into the naming module (28 places), the validator (`envs must be exactly dev and prd`), stack code (`each.key == "prd"`, `databricks.dev` and `databricks.prd` providers) and `access_matrix.yaml` keys (`dev_readers`, `overrides: dev:`).

**Change.**
- `config/platform.yaml`: each environment gets `tier` (`nonprod` or `prod`), `promotes_from` (a list of environments, empty means any commit) and `allow_hotfix`.
- `modules/naming/main.tf`: `env_tier`, `prod_env`, `nonprod_envs` replace every literal. Consumer groups, consumer catalogs and warehouses, the anonymized catalog and its writer, experiments and the observability stack use the prod environment. Sandboxes use nonprod environments. Anonymized data is read from every nonprod environment.
- `config/access_matrix.yaml`: `service_principal_only_in_prd` becomes `service_principal_only_in_prod`; `vault.overrides` and `anon` are keyed by tier (`nonprod`, `nonprod_readers`); a bundle may be `{ nonprod: ..., prod: ... }`; `bundle_order` and `override_ceiling` added. `workspace_objects.yaml`: `dev_only` becomes `nonprod_only`.
- `scripts/validate_config.py`: exactly one prod environment, valid tiers, `promotes_from` names known environments and has no cycle.
- `<env>-workspace-admins` is generated for every environment.

**Rationale.** Rules follow the tier, so a new environment needs no code change. `promotes_from` lists any number of environments, so the environments form a graph (qa after dev1 and dev2, uat after qa, prd after uat).

**Acceptance.**
- Two environments marked `prod` are rejected by the naming module and the validator.
- Adding an environment needs only config (`platform.yaml`, persona `access`, budgets in `cost.yaml`, platform group `workspaces`); see ARCHITECTURE.md section 13.
- `grep` for `"dev"` and `"prd"` in `modules/naming/main.tf` finds none outside comments and messages.

---

### C-2. Scopes and one Terraform state per scope

**Objective.** Deploying claims in prd can only read and change claims in prd.

**Finding.** Each stack held every environment and every domain in one state. One apply compared and could change all of them.

**Change.**
- Every item the naming module produces carries a `scope` and an `sid`: `shared`, `<env>/env`, `<env>/access` or `<env>/domain:<name>`. The module is always computed in full; its new `environment` and `scope` variables only filter the outputs. New outputs `all_group_names` and `all_service_principal_names` let a stack refer to objects owned by another scope by name.
- A group-in-group edge is owned by its **parent's** scope, except an edge into a shared group, which is owned by the **child's** scope (so `shared` never depends on an environment); a group owned by another scope is found by display name.
- Each stack takes `environment` and `scope` variables and declares the scopes it supports in `stacks/<stack>/stack.yaml`:

| Stack | Scopes |
|---|---|
| 10-foundation | env |
| 20-identity | shared, env, domain |
| 25-access | access |
| 30-account | shared, env, domain |
| 40-unity-catalog | shared, env, domain |
| 50-workspace | env, domain |
| 55-ai-platform | env, domain |
| 60-governance | env, domain |
| 70-observability | env (prod environment only) |

- One Databricks workspace provider chosen by `environment` replaces the `databricks.dev` / `databricks.prd` pairs and the duplicated `module "x_dev"` / `"x_prd"` blocks.
- `modules/uc_environment`: the environment's one storage credential is created only in the `env` scope (`create_credential`); a domain run refers to it by name. `modules/workspace_config` and `modules/ai_platform` get `manage_workspace` / `manage_env_objects` so a domain run creates only its own warehouse, App Space and Lakebase project.
- Stack 30 finds groups, service principals and users in Entra by name, so it no longer reads stack 20's state.
- State keys: `<stack>/shared.tfstate`, `<stack>/<env>/env.tfstate`, `<stack>/<env>/access.tfstate`, `<stack>/<env>/domain-<name>.tfstate` (`util/scope.py`, `scripts/state_key.py`, `scripts/tf.sh`).

**Rationale.** Separate states are the real protection. Names, not remote state, link scopes, so no run needs another run's state.

**Acceptance.**
- The partition test proves every item belongs to exactly one scope and the scopes together cover everything.
- For every stack, the resources planned across all its targets equal the old combined plan (for example 347 for stack 40). This is checked by the mocked plans.

---

### C-3. Wrappers: scoped plan, apply, check, scope check, promotion gate, releases, records

**Objective.** One entry point, local and in CI, that cannot apply the wrong thing.

**Change.** All take `<stack> --scope <scope> [--env <env>]`.

| Tool | What it does |
|---|---|
| `scripts/tf.sh` | Runs Terraform for one target; sets the state key; `init` always uses `-reconfigure` |
| `scripts/plan.py` | Init, plan, save the plan and its JSON, run the scope check (exit 4 on a violation) |
| `scripts/apply.py` | Resolve the target; work out the release; promotion gate (exit 5); plan or take `--plan FILE`; scope check; confirm; apply the saved plan; run the checks; write the deploy record. `--yes` needs `--plan` (exit 2). `--hotfix --approver NAME` where allowed |
| `scripts/check.py` | Runs `stacks/<stack>/checks.py`; each check gets the outputs and a `Context` holding the naming output for the target |
| `scripts/plan_all.py` | Read-only plan of every target of an environment; exit 2 when anything has changes |
| `scripts/release.py` | Cuts `rel-YYYY.MM.DD.N` on a clean commit that validates |
| `scripts/status.py` | Latest successful release per target |
| `util/scope_check.py` | Refuses a plan that changes a resource whose instance key belongs to another scope. A second lock behind C-2; an unattributable key is a note, not a failure |
| `util/deploys.py` | Deploy records (container `deployments` in the state storage account) and the promotion gate |
| `util/naming_eval.py` | The one evaluator of the naming module, used by tests, checks and wrappers. `util/config_reader.py` (which copied the naming rules in Python) is removed |

The promotion gate: an environment with `promotes_from` accepts only a release tag, `HEAD` must be that tag's commit with a clean tree, and every listed environment must hold a `PASS` record for the same release, stack and scope. An empty plan still records the release.

**Acceptance.**
- `apply.py --yes` without `--plan` exits 2.
- A prd deploy of a release that never reached dev exits 5.
- A plan mixing claims and profitability resources exits 4 and names the foreign resource.

---

### C-4. Pipelines

**Objective.** Dev and prd have separate pipelines, approvals and identities; the approver reads the plan that is applied.

**Change.**
- `deploy.yml` (dispatch): inputs `stack`, `environment`, `scope`, `ref`, `hotfix`, `approver`. Job `plan` runs in GitHub environment `<env>-plan`, saves the plan and shows it in the job summary. Job `apply` runs in `<env>` (required reviewers on the prod environment), downloads the **same** plan, applies it, runs the checks and writes the record. Scope `shared` uses the GitHub environments `shared-plan` and `shared`. One deploy of a target at a time.
- `release.yml` (dispatch): config, `terraform fmt`, naming tests, wrapper tests and mocked plans, then `scripts/release.py --push`.
- `plan.yml` (pull request): plans every target of the first nonprod environment and comments a table.
- `drift.yml` (nightly): plans every target of every environment, never applies; fails when anything has changes.
- `validate.yml` also runs the wrapper tests. `apply.yml` is removed.
- `provision-access.yml` and `scripts/provision_access.py` now edit `config/entitlements/<env>/` and take `--env`. `CODEOWNERS` gets stricter reviewers for `config/entitlements/prd/` and covers `domain_shape`, `domain_access`, workflows, `scripts/` and `util/`.

**Acceptance.** A prd deploy waits for approval and applies the plan that was shown. A dev merge changes nothing until someone dispatches a deploy. *Not yet exercised on GitHub.*

---

### C-5. One Terraform identity and one resource group per environment

**Objective.** A dev pipeline cannot change prd's Azure resources.

**Change.** `bootstrap/` creates `rg-piq-<env>`, `sp-piq-terraform-<env>` (Azure Contributor and RBAC Administrator on that resource group only; Graph permissions as before) and keeps `sp-piq-terraform` for the shared scope. OIDC subjects: `environment:<env>`, `environment:<env>-plan`, `environment:shared`, `environment:shared-plan` (the old `pull_request` and `platform` subjects are gone). Stack 10 looks up the resource group instead of creating it. Stack 20's shared scope adds every Terraform identity to `piq-metastore-admins`. New outputs: `github_variables` (per environment), `env_terraform_sps`, `next_steps`.

**Honest limits.** Entra Graph permissions and Databricks account admin cannot be limited per environment, so a dev identity is not technically blocked from prd groups. The state storage account is shared. Administrative units (CR-001) and per-environment state containers would close these. Whether Contributor on the resource group is enough to create a Databricks workspace has not been tested against real Azure.

**Acceptance.** `terraform validate` passes for `bootstrap/`. *Not yet applied.*

---

### C-6. Entitlements folder and stack `25-access`

**Objective.** Everything an IAM tool would own can be separated by deleting one folder and one stack.

**Change.**
- `config/entitlements/<env>/` holds `personas.yaml`, `product_access.yaml`, `sars.yaml`, `sandboxes.yaml`, `experiments.yaml`, `admins.yaml`. Moved here: persona `members`, `consumers:` from `config/products/*.yaml`, SAR `members` from `config/sars.yaml`, `config/sandbox_users.yaml`, `config/experiments.yaml`, domain `admins`.
- Stack `25-access` (scope `access`, one run per environment) adds people to groups and nests approved consumers and SAR members. It finds groups and users by name. Stack 20 creates groups empty and never adds people.
- Sandbox and experiment schemas are still created by stack 40's `env` scope from these files, because they are Unity Catalog objects.
- Approvals are per environment: a consumer can be approved in dev before prd.

**Rationale.** Grants of privileges on data stay in this repo (they must match the objects it creates). Who is in which group is the IAM tool's job. The group names are the contract.

**Acceptance.** Removing the `config/entitlements/` folder leaves a valid configuration with no memberships. Entitlement files in the wrong tier (sandboxes in prod, experiments in nonprod, a consumer domain approved outside prod) are rejected.

---

### C-7. Personas per environment

**Objective.** A person can be a data-engineer in dev and only a data-analyst in prd.

**Change.** `config/personas.yaml`: each persona has `access: { <env>: [group references] }` (an empty list is allowed; every environment must be listed). Groups are `piq-<env>-persona-<name>`. A persona may only reference its own environment's groups and workspaces. Who holds a persona is an entitlement (C-6). `test_users.yaml` uses `persona:<env>:<name>`.

**Acceptance.** A dev persona nested into a prd group, or a prd persona given the dev-only `sandbox-users` workspace, is rejected by the naming module and the validator.

---

### C-8. Domain shape and domain access

**Objective.** A domain can have schemas, roles and personas the others do not, inside a common structure.

**Change.**
- `config/domain_shape/<domain>.yaml` (domain team): schemas to add or remove, extra roles (`service_principal_only` optional), domain personas.
- `config/domain_access/<domain>.yaml` (platform and governance): schema access per role, product-schema access, warehouse `CAN_USE` / `CAN_MANAGE`, domain persona access per environment.
- The naming module computes per-domain roles and schemas; "all roles" became "this domain's roles"; the wildcard `dev:*:analyst` means every domain that defines the role.
- Limits: bundle at most `override_ceiling` (`RWC`); `admin` untouchable; no name collisions; a domain persona may only reference its own domain's roles. Domain role groups and domain personas belong to the domain scope.

**Acceptance.** A domain with an extra schema, role and persona gets exactly those, and no other domain does. An override above the ceiling, a collision, and a domain persona reaching another domain are rejected.

---

### C-9. Tests

| Test | Covers |
|---|---|
| `tests/naming/run_tests.py` (`make test`) | Names, nesting, grants, masks; the **partition test** (every item has exactly one scope, scopes cover everything); a domain with additions; negative cases rejected by both the naming module and the validator |
| `tests/wrappers/run_tests.py` | State keys, target validation, the scope check (including every scope's own items), the promotion gate (including a graph of environments), release tags, `apply.py` refusals |
| `tests/stacks/run_plan_tests.py` (`make plan-test`) | A mocked plan of every stack for every target; resource counts equal the old combined plan |
| `terraform validate` | Every stack and `bootstrap/` |

---

### C-10. Documentation

`ARCHITECTURE.md`, `ARCHITECTURE-FEDERATION.md`, `DECISIONS.md` (ADR-022 to ADR-029), `CONCEPTS.md`, `CONFIGURATION.md`, `OPERATIONS.md`, `RUNBOOK.md`, `TROUBLESHOOTING.md` and `CLAUDE.md` describe the new model.

---

## 6. What has and has not been verified

| Verified (no cloud) | Not verified |
|---|---|
| Config rules and the naming module (`make test`) | Real provider behaviour against Azure, Entra and Databricks |
| The partition of every item into one scope | The per-environment resource-group rights creating a workspace |
| State keys, scope check, promotion gate, release tags | GitHub environments, required reviewers and OIDC trust |
| Mocked plan of every stack and target; counts match the old plan | Deploy records in blob storage (`BlobStore`) |
| `terraform validate` of every stack and `bootstrap/` | The `plan_all.py`, `status.py` and `deploy.yml` paths end to end |

## 7. Not in scope

- Domain repositories running their own deploys (CR-001 sections 4 and 5, `templates/domain-bundle`).
- Choosing or integrating an IAM product. Only the seam is built.
- A per-environment Azure subscription.
- Separate state containers per environment, and Entra administrative units.

## 8. Implementation and deploy order

Implementation order was C-1, C-2, C-6/C-7/C-8 (config and naming), tests, stacks, wrappers, pipelines, bootstrap, documentation.

Deploy order for each environment (a `domain` step repeats for every domain):

1. `10-foundation` env
2. `20-identity` shared (once), env, every domain
3. `25-access`
4. Manual, once: claim the Databricks account, make `piq-metastore-admins` the metastore admin, add every Terraform identity as account admin
5. `30-account` shared (once), env, every domain
6. `40-unity-catalog` shared (once; after stack 30 has finished for every environment, because its tag-assigner rules name every environment's groups), env (creates the storage credential), every domain
7. `50-workspace` env, every domain; `55-ai-platform` env, every domain
8. `60-governance` env (creates the masking functions), every domain
9. `70-observability` env (prod environment only)

Adding a domain: `10-foundation` env (new storage container) → `20-identity` domain:new → `30-account` domain:new → `30-account` env → `40-unity-catalog` env (vault grants) → `40-unity-catalog` domain:new → `50`, `55`, `60` domain:new → `25-access`.

## 9. Overall acceptance

- `make test`, `make plan-test`, `terraform fmt -recursive -check` and `terraform validate` pass with no cloud access.
- After the rebuild: planning `domain:claims` after editing only `config/products/policy_financial.yaml` shows no changes; planning `domain:policy_financial` shows only that change.
- A prd deploy of a tag that never reached dev is refused; after the dev deploy it is accepted.
- A hand change to a grant in dev appears in the nightly drift report and is reverted by deploying that target.
