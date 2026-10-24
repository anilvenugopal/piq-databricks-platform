# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install Python dependencies and the util package (run once, and after pulling)
pip install -r requirements.txt

# Validate config/ files (mirrors Terraform preconditions, catches cycles/UPN/CIDR errors)
python3 scripts/validate_config.py

# Check Terraform formatting
terraform fmt -recursive -check

# Run naming module and validator tests (27 positive + 6 negative, no cloud access needed)
make test
# or: python3 tests/naming/run_tests.py

# Mocked plan of every stack (downloads providers; no cloud credentials needed)
make plan-test
# or: python3 tests/stacks/run_plan_tests.py
# or for a single stack: python3 tests/stacks/run_plan_tests.py 40-unity-catalog

# Plan only — review the diff before committing to an apply
python3 scripts/plan.py <stack>

# Plan + confirm + apply + validate + write audit record
python3 scripts/apply.py <stack>           # interactive (prompts for confirmation)
python3 scripts/apply.py <stack> --yes     # non-interactive (CI)

# Validate a deployed stack at any time (no apply required)
python3 scripts/check.py <stack>

# Low-level Terraform wrapper (still valid; used by the scripts above internally)
./scripts/tf.sh <stack> init
./scripts/tf.sh <stack> plan -out tfplan
./scripts/tf.sh <stack> apply tfplan

# Use OpenTofu instead of Terraform
TF_BIN=tofu make test
TF_BIN=tofu make plan-test
TF_BIN=tofu python3 scripts/apply.py <stack>
```

## Architecture

### How configuration drives everything

All infrastructure is derived from `config/`. No hardcoded names exist in Terraform — everything flows through `modules/naming/main.tf`, which is a pure computation module (no providers, no resources). Every stack calls `module "naming"` and reads names, groups, grants, catalogs, schemas, and warehouses from its outputs.

The key files:
- `config/platform.yaml` — prefix, environments, Azure tenant/subscription, GitHub org, state backend
- `config/domains.yaml` — producer domains and vault definition (schemas, sources)
- `config/products/<domain>.yaml` — products published by each domain and their approved consumers
- `config/consumers/<name>.yaml` — consumer-only domains with their roles and warehouse config
- `config/access_matrix.yaml` — privilege bundles (R/RW/O/etc.) mapped to roles and schema types
- `config/personas.yaml` — platform groups and human personas with their group memberships
- `config/sars.yaml` — Sensitive Access Roles that unlock ABAC column masks
- `config/governed_tags.yaml` — Unity Catalog tag taxonomy and masking policies

Publishing a product, approving a consumer, or granting a SAR is a pull request that edits one YAML file.

### Naming rule

The environment (`dev`/`prd`) appears **only** in names whose scope spans environments: catalogs (`dev_claims`), Entra groups (`piq-dev-claims-producer`), service principals, usage policies. It never appears in schema names, warehouse names, or workspace objects. This means domain code is environment-free.

### Stack layering

Stacks are numbered and must be applied in order. Each stack reads prior state via `terraform_remote_state`. The naming module is re-evaluated in every stack, so it always reflects the current config.

```
10-foundation  → Azure resources (VNets, storage, workspaces, key vaults)
20-identity    → Entra groups, service principals, user memberships (reads 10)
30-account     → Databricks account: group/SP sync, usage policies, budgets (reads 10, 20)
40-unity-catalog → Catalogs, schemas, volumes, grants, governed tags, ABAC (reads 10, 30)
50-workspace   → Warehouses, compute policies, IP access lists (reads 10, 40)
55-ai-platform → App Spaces, vector search, Lakebase (reads 10, 30)
60-governance  → Column masks, SAR assignments, sensitive tag grants (reads 10, 50)
70-observability → System table views for cost, query, audit, lineage (reads 10, 50)
```

Phase 4 (between stacks 20 and 30) is a one-time manual step: claim the Databricks account and set the metastore admin.

### Group key convention

Groups are keyed as `"<env>:<domain>:<role>"` (e.g., `"prd:claims:producer"`), `"product:<env>:<product>"`, `"consumer:<consumer>:<role>"`, `"vault:<env>:<role>"`, `"sar:<env>:<sar>"`, `"platform:<key>"`, or `"persona:<name>"`. This key scheme is used consistently in nesting, grants, and workspace assignments across the naming module.

### ABAC masking model

Column masking is catalog-scoped. For each (catalog × mask) pair, `modules/naming` produces an `abac_policies` entry with a `function`, `condition`, and `except` list. Only SAR groups and the catalog's writer group are in `except` — everyone else sees the masked value. Stack 60 applies these as `databricks_column_mask` policies.

### Tests

`tests/naming/run_tests.py` spins up a throwaway Terraform workspace, evaluates the naming module against `config/`, and asserts specific group names, nesting relationships, catalog/schema grants, warehouse assignments, and ABAC exceptions. It also runs six negative cases that mutate config/, expecting both the Terraform precondition and the Python validator to reject the change.

`tests/stacks/run_plan_tests.py` copies each stack to a temp dir, generates a `.tftest.hcl` that mocks all providers and overrides `terraform_remote_state` with values derived from the naming module, then runs `terraform test -command=plan`. This validates resource wiring and type correctness without cloud access.

### CI

The `validate` workflow (`.github/workflows/validate.yml`) runs on every PR without cloud credentials: config validation, `terraform fmt`, naming tests, mocked plans, and `terraform validate` for every stack. The `plan` and `apply` workflows use Azure OIDC (no stored secrets).

### CODEOWNERS

Ownership is enforced by branch protection. Producing domain teams own their `config/products/<domain>.yaml`. Consumer leads own their `config/consumers/<name>.yaml`. The governance team owns tags, masks, SARs. The access matrix and naming module require both platform and governance approval.
