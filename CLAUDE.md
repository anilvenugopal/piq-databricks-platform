# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

A deployment **target** is a stack + a scope + (except scope `shared`) an environment. Scopes: `shared`, `env`, `access`, `domain:<name>`. Every script and make target takes it as `<stack> --scope <scope> [--env <env>]`.

```bash
# Install Python dependencies and the util package (run once, and after pulling)
pip install -r requirements.txt

# Validate config/ files (mirrors Terraform preconditions, catches cycles/UPN/CIDR/tier/shape errors)
python3 scripts/validate_config.py

# Check Terraform formatting
terraform fmt -recursive -check

# Naming module + validator tests, and deployment wrapper tests (no cloud access needed)
make test
# or: python3 tests/naming/run_tests.py && python3 tests/wrappers/run_tests.py

# Mocked plan of every stack for every target (downloads providers; no cloud credentials needed)
make plan-test
# or: python3 tests/stacks/run_plan_tests.py
# or for a single stack: python3 tests/stacks/run_plan_tests.py 40-unity-catalog

# Plan one target, run the scope check, save the plan
python3 scripts/plan.py 40-unity-catalog --env dev --scope domain:claims
make plan STACK=40-unity-catalog ENV=dev SCOPE=domain:claims

# Release check + promotion gate + plan + confirm + apply the saved plan + checks + deploy record
python3 scripts/apply.py 40-unity-catalog --env prd --scope domain:claims --release rel-2026.10.23.1
python3 scripts/apply.py <stack> --scope <scope> --env <env> --plan FILE --yes   # CI: --yes needs --plan
# --hotfix --approver NAME skips the promotion gate where the environment has allow_hotfix: true
# exit codes: 0 ok, 1 failed, 2 declined / --yes without --plan, 4 scope check, 5 promotion gate

# Post-apply checks of a deployed target
python3 scripts/check.py <stack> --scope <scope> --env <env>

# Plan every target of an environment, read-only (what a merge would change; drift)
python3 scripts/plan_all.py --env dev          # make plan-all ENV=dev

# Releases and status
python3 scripts/release.py [--push|--list]     # cuts rel-YYYY.MM.DD.N on HEAD
python3 scripts/status.py [--env dev]          # which release is deployed where

# Edit entitlements from an approved request (always needs --env)
python3 scripts/provision_access.py persona --env prd --upn jane@corp.com --name data-analyst

# Low-level Terraform wrapper (used by the scripts above): sets the state key for the target
./scripts/tf.sh <stack> --scope <scope> [--env <env>] init
./scripts/tf.sh <stack> --scope <scope> [--env <env>] plan -out x.tfplan

# Use OpenTofu instead of Terraform
TF_BIN=tofu make test
TF_BIN=tofu make plan-test
```

Nothing from the scope/release/entitlement design has been applied to real cloud yet; it is checked by the tests above and `terraform validate`.

## Architecture

### How configuration drives everything

All infrastructure is derived from `config/`. No hardcoded names exist in Terraform — everything flows through `modules/naming/main.tf`, which is a pure computation module (no providers, no resources). Every stack calls `module "naming"` and reads names, groups, grants, catalogs, schemas, and warehouses from its outputs. `util/naming_eval.py` is the one Python evaluator of that module (tests, scope check, checks all use it).

The key files:
- `config/platform.yaml` — prefix, environments (`tier`, `promotes_from`, `allow_hotfix`, network), Azure tenant/subscription, GitHub org, state backend
- `config/domains.yaml` — producer domains, the standard private schemas, vault definition
- `config/domain_shape/<domain>.yaml` (domain team) and `config/domain_access/<domain>.yaml` (platform + governance) — what one domain adds to or changes from the standard: schemas, roles, personas, and what they may do
- `config/products/<domain>.yaml` — products published by each domain (who may read them is an entitlement)
- `config/consumers/<name>.yaml` — consumer-only domains with their roles and warehouse config
- `config/access_matrix.yaml` — privilege bundles (R/RW/RWC/O) mapped to roles and schema types, `bundle_order`, `override_ceiling`, tier-aware values
- `config/personas.yaml` — global personas (access per environment) and platform groups
- `config/sars.yaml` — Sensitive Access Role definitions that unlock ABAC column masks
- `config/governed_tags.yaml` — Unity Catalog tag taxonomy and masking policies
- `config/entitlements/<env>/` — personas, product approvals, SAR members, sandboxes, experiments, domain admins per environment

Publishing a product is a pull request on one products file. Approving a consumer, granting a SAR or adding a person to a persona is a pull request on `config/entitlements/<env>/`.

### Naming rule

The environment appears **only** in names whose scope spans environments: catalogs (`dev_claims`), Entra groups (`piq-dev-claims-producer`), service principals, usage policies. It never appears in schema names, warehouse names, or workspace objects. This means domain code is environment-free. Rules depend on an environment's **tier** (`nonprod`/`prod`; exactly one prod), never on its name.

### Scopes and state

Every group, catalog, schema, grant, policy, warehouse and service principal belongs to exactly one scope, stamped on it as `sid` (`shared`, `<env>/env`, `<env>/domain:<name>`, `<env>/access`). The naming module is always computed in full; its `environment` and `scope` variables only filter the outputs to what one run owns. A run has its own state: `<stack>/shared.tfstate`, `<stack>/<env>/env.tfstate`, `<stack>/<env>/access.tfstate`, `<stack>/<env>/domain-<name>.tfstate` (`util/scope.py`). Scopes refer to each other by computed names, not by reading each other's state. A nesting edge is owned by its parent group's scope (an edge into a shared group is owned by the child's scope, so `shared` never depends on an environment); a group from another scope is found by display name.

`tests/naming` proves every item has exactly one scope (partition test); mocked plans show the scoped plans add up to the old combined plan. `util/scope_check.py` refuses a saved plan that changes anything the target does not own.

### Stack layering

Stacks are numbered. Each declares its scopes in `stacks/<stack>/stack.yaml`.

```
10-foundation    env                  Azure: VNet, storage, workspace, key vault (resource group comes from bootstrap/)
20-identity      shared|env|domain    Entra groups, nesting of personas, service principals (no memberships)
25-access        access               Memberships and approvals from config/entitlements/<env>/
30-account       shared|env|domain    Databricks account: AIM, workspace assignment, usage policies, budgets
40-unity-catalog shared|env|domain    Tags (shared); credential + vault/platform/sandbox/consumer catalogs (env); domain catalog (domain)
50-workspace     env|domain           Workspace settings, compute policies (env); domain warehouse (domain)
55-ai-platform   env|domain           Vector search (env); App Space, Lakebase (domain)
60-governance    env|domain           Masking functions (env); column-mask policies (catalog's scope)
70-observability env                  System table views, prod environment only
```

Order, first environment: 10 env; 20 shared, env, each domain; 25; Phase 4 (manual, once: claim the Databricks account, make `piq-metastore-admins` the metastore admin, add every Terraform identity as account admin); 30 shared, env, each domain; 40 shared (after 30 has finished for every environment), env, each domain; 50, 55, 60 env then each domain; 70 env. 40 domain needs the credential from 40 env; 60 domain needs the functions from 60 env. Adding a domain: 10 env, 20 domain, 30 domain, 30 env, 40 env (vault grants), 40 domain, 50/55/60 domain, 25.

### Releases and promotion

`main` is the only long-lived branch. `scripts/release.py` cuts `rel-YYYY.MM.DD.N`. An environment with `promotes_from` accepts only a release tag that was deployed successfully (same stack and scope) to **every** environment listed; HEAD must be the tag with a clean tree (`util/deploys.py`, records in the `deployments` container of the state storage account). Environments with empty `promotes_from` accept any commit. Empty plans still record the release as deployed.

### Entitlements

Who is in which group and which approvals exist is entitlement data, applied only by `25-access`. It stands in for an IAM tool (SailPoint, Saviynt); to hand over, delete `config/entitlements/` and stack 25. Group names are the contract.

### Group key convention

Groups are keyed as `"<env>:<domain>:<role>"` (e.g., `"prd:claims:producer"`), `"writer:<env>:<domain>"`, `"product:<env>:<product>"`, `"consumer:<consumer>:<role>"`, `"vault:<env>:<role>"`, `"sar:<env>:<sar>"`, `"platform:<key>"`, `"persona:<env>:<name>"`, or `"persona:<env>:<domain>:<name>"`. This key scheme is used consistently in nesting, grants, and workspace assignments across the naming module. Persona groups are named `piq-<env>-persona-<name>` and `piq-<env>-persona-<domain>-<name>`.

### ABAC masking model

Column masking is catalog-scoped. For each (catalog × mask) pair, `modules/naming` produces an `abac_policies` entry with a `function`, `condition`, and `except` list. Only SAR groups and the catalog's writer group are in `except` — everyone else sees the masked value. Stack 60 applies these as `databricks_policy_info` column-mask policies; the catalog's scope owns each policy.

### Tests

`tests/naming/run_tests.py` evaluates the naming module (through `util/naming_eval.py`) against `config/` and asserts group names, nesting, grants, warehouses and ABAC exceptions; a partition test over every scope; a copy of config with domain additions; and negative cases that mutate config/, expecting both the Terraform precondition and the Python validator to reject the change.

`tests/wrappers/run_tests.py` covers scopes and state keys, the scope check, the promotion gate (including environment graphs and hotfix), releases and apply.py's safety rules.

`tests/stacks/run_plan_tests.py` copies each stack to a temp dir, generates a `.tftest.hcl` that mocks all providers and overrides `terraform_remote_state`, then runs one `plan` per target of the stack. This validates resource wiring and type correctness without cloud access.

### CI

`validate.yml` runs on every PR without cloud credentials: config validation, `terraform fmt`, naming and wrapper tests, mocked plans, `terraform validate` for every stack. `plan.yml` (PR) plans every target of the first nonprod environment. `deploy.yml` (by hand) has a plan job and, after approval, an apply job that applies the saved plan. `release.yml` tags a release. `drift.yml` is a nightly plan-only run. `provision-access.yml` turns approved requests into entitlement PRs. All use Azure OIDC (no stored secrets) through GitHub environments `<env>`, `<env>-plan`, `shared`, `shared-plan`; `bootstrap/` creates a Terraform identity per environment with Azure rights limited to its resource group (Entra and Databricks account rights cannot be limited that way).

### CODEOWNERS

Ownership is enforced by branch protection. Producing domain teams own their `config/products/<domain>.yaml` and `config/domain_shape/<domain>.yaml`. Consumer leads own their `config/consumers/<name>.yaml`. The governance team owns tags, masks, SARs. The access matrix, `config/domain_access/`, the naming module and the workflows require both platform and governance approval; `config/entitlements/prd/` does too.
