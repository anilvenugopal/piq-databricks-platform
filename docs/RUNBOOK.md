# Runbook: first-time setup

Ten phases, in order. Each ends with a **Verify** step; do not continue until it
passes. Manual steps are marked **MANUAL**; everything else is Terraform.

Time: about a day spread over a week. Cost while idle: a few dollars a month for
storage and Key Vault; NAT gateway (if enabled) about USD 32/month; compute is pay
per use and serverless scales to zero.

---

## Phase 1: Accounts and tooling (MANUAL, about 1 hour)

1. Create an Azure pay-as-you-go subscription. Its Entra tenant comes with it and
   you are its Global Administrator.
2. In Azure Cost Management, create a **subscription budget** (for example
   USD 100/month) with email alerts at 50/80/100%.
3. Register resource providers:
   ```bash
   az login
   for p in Microsoft.Databricks Microsoft.Storage Microsoft.Network Microsoft.KeyVault Microsoft.ManagedIdentity; do
     az provider register --namespace $p
   done
   ```
4. Install: Azure CLI, Terraform >= 1.6, Databricks CLI, Python 3.11+, git.
   `pip install -r requirements.txt`.
5. Create the private GitHub repo and push this code. Create GitHub environment
   **`platform`** with yourself as required reviewer, deployment branch `main`.
6. Edit `config/platform.yaml`: `tenant_id`, `subscription_id`, `location`,
   `unique_suffix`, `state.storage_account`, `github.org`, `notifications.ops_email`.
   Leave `databricks.account_id` as zeros for now.

**Verify:** `python3 scripts/validate_config.py` prints `Config OK`.

## Phase 2: Bootstrap (local Terraform, once)

```bash
cd bootstrap
terraform init
terraform plan -out tfplan       # expect ~15 resources
terraform apply tfplan
terraform output github_variables
```

Add the three outputs as GitHub **repository variables** (Settings → Secrets and
variables → Actions → Variables): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`. None are secrets.

Back up `bootstrap/terraform.tfstate` (it is git-ignored). Optionally move it into
the state container: add `backend "azurerm" {}` to `bootstrap/main.tf`, then
`terraform init -migrate-state` with the same `-backend-config` values `scripts/tf.sh`
uses and `key=bootstrap.tfstate`.

**Verify:** in Entra ID → App registrations, `sp-piq-terraform` exists, has two
federated credentials, and Microsoft Graph API permissions show "Granted".

## Phase 3: Foundation (CI)

Run the **apply** workflow with `stack = 10-foundation`, approve the `platform`
environment. Or locally while learning:

```bash
./scripts/tf.sh 10-foundation init
./scripts/tf.sh 10-foundation plan -out tfplan
./scripts/tf.sh 10-foundation apply tfplan
./scripts/tf.sh 10-foundation output workspaces
```

Workspace creation takes 5–10 minutes each. The first Premium workspace creates
your Databricks account.

**Verify:** both workspace URLs open in a browser and you can sign in.

## Phase 4: Claim the Databricks account (MANUAL, once)

1. Open `https://accounts.azuredatabricks.net` and sign in as the Global
   Administrator. The first sign-in makes you an **account admin**.
2. Copy the **Account ID** (top-right menu) into `config/platform.yaml`
   (`databricks.account_id`), commit and push.
3. Settings → **Automatic identity management**: confirm it is enabled (default for
   new accounts).
4. User management → Service principals → **Add** → search Entra for
   `sp-piq-terraform` → add it → open it → **Roles** → enable **Account admin**.
5. Apply **stack 20-identity** now (next phase), then return here for step 6.
6. Catalog → the regional metastore → **Metastore admin** → set to the group
   `piq-metastore-admins` (it contains the Terraform SP after stack 20).

**Verify:** account console → Workspaces lists both workspaces; Catalog shows the
metastore with admin `piq-metastore-admins`.

## Phase 5: Identity and account (CI)

```bash
./scripts/tf.sh 20-identity init && ./scripts/tf.sh 20-identity plan -out tfplan && ./scripts/tf.sh 20-identity apply tfplan
# Phase 4 step 6 now, then:
./scripts/tf.sh 30-account init && ./scripts/tf.sh 30-account plan -out tfplan && ./scripts/tf.sh 30-account apply tfplan
```

Get test-user passwords (training only):
```bash
./scripts/tf.sh 20-identity output -json test_user_credentials
```

**Verify:** account console → Groups shows `piq-*` groups as **External**; each
workspace → Settings → Identity and access lists the functional groups. Sign in to
the dev workspace as `test.analyst` (you will be asked to change the password).

## Phase 6: Unity Catalog (CI)

```bash
./scripts/tf.sh 40-unity-catalog init && ./scripts/tf.sh 40-unity-catalog plan -out tfplan
```

Read the plan: about 10 catalogs, 60+ schemas, 12 volumes, tag policies, grants.

```bash
./scripts/tf.sh 40-unity-catalog apply tfplan
```

**Verify** (dev workspace SQL editor, as yourself):
```sql
SHOW CATALOGS;                       -- dev_* only; no prd_* catalogs here
SHOW GRANTS ON SCHEMA dev_claims.gold;
DESCRIBE CATALOG EXTENDED dev_claims;  -- isolation mode ISOLATED
```

## Phase 7: Workspace configuration (CI)

```bash
./scripts/tf.sh 50-workspace init && ./scripts/tf.sh 50-workspace plan -out tfplan && ./scripts/tf.sh 50-workspace apply tfplan
./scripts/tf.sh 55-ai-platform init && ./scripts/tf.sh 55-ai-platform plan -out tfplan && ./scripts/tf.sh 55-ai-platform apply tfplan
```

**Verify:** SQL Warehouses shows `piq-dev-etl` and `piq-dev-bi` (serverless,
stopped). As `test.analyst`, `piq-dev-bi` is usable and `piq-dev-etl` is not
listed. Settings → Developer → Access tokens is unavailable.

## Phase 8: Governance and observability (CI)

Stacks 60 and 70 run SQL through `scripts/run_sql.py`, so the runner needs Python
with `databricks-sdk` (CI installs it).

```bash
./scripts/tf.sh 60-governance init && ./scripts/tf.sh 60-governance plan -out tfplan && ./scripts/tf.sh 60-governance apply tfplan
./scripts/tf.sh 70-observability init && ./scripts/tf.sh 70-observability plan -out tfplan && ./scripts/tf.sh 70-observability apply tfplan
```

**Verify:**
```sql
SHOW FUNCTIONS IN dev_platform.governance;   -- mask_ssn, mask_dob, mask_email, mask_phone, mask_name
SHOW POLICIES ON CATALOG dev_claims;         -- five mask_* policies
SELECT * FROM prd_platform.monitoring.cost_daily_by_env_domain LIMIT 10;   -- in prd workspace
```

## Phase 9: Prove the access design

Run `sql/labs/lab06_masking_test.sql`: section A as `test.engineer` (dev producer),
sections B–D as `test.analyst`. Expected:

| Check | Expected |
|---|---|
| Producer reads `dev_claims.silver.claimant` | raw values |
| Analyst reads the same table | `[REDACTED]`, `***-**-6789`, year-only DOB, masked email/phone |
| Analyst reads `dev_claims.bronze.*` | `PERMISSION_DENIED` |
| Analyst references `prd_claims` from dev | catalog not accessible |
| `prd_platform.audit.denied_requests` | shows the analyst's refused attempts |

## Phase 10: Day-2 readiness

1. Wire the access portal to `.github/workflows/provision-access.yml` (the Worker
   writes the `<!-- piq-access {...} -->` block into the issue body).
2. Turn on branch protection: require PR reviews and Code Owner review on `main`.
3. Practise each procedure in [OPERATIONS.md](OPERATIONS.md) once.
4. After a week, review `prd_platform.monitoring.cost_untagged_usage` and the
   serverless egress denial logs, then set prd `enforcement_mode: ENFORCED`.
