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
   > **What this does:** Azure requires you to explicitly "opt in" to each service
   > before you can create resources with it. `az provider register` tells your
   > subscription "I want to use this service." It is a one-time step per subscription.
   > The command is safe to run more than once — re-registering an already-registered
   > provider is a no-op.
   >
   > **How to check it worked:**
   > ```bash
   > for p in Microsoft.Databricks Microsoft.Storage Microsoft.Network Microsoft.KeyVault Microsoft.ManagedIdentity; do
   >   echo "$p: $(az provider show --namespace $p --query registrationState -o tsv)"
   > done
   > ```
   > Every line should print `Registered`. It can take a minute or two; run again if
   > any still show `Registering`.

4. Install: Azure CLI, Terraform >= 1.6, Databricks CLI, Python 3.11+, git.
   `pip install -r requirements.txt`.

5. Create the GitHub repository and push this code:

   **a. Create the repo on GitHub:**
   - Go to [github.com/new](https://github.com/new) (or your GitHub organisation's
     equivalent).
   - Name it `piq-databricks-platform` (or whatever you prefer — you will put this
     name in `config/platform.yaml` later).
   - Set it to **Private**.
   - Do **not** initialise it with a README (the repo already has one).

   **b. Push this code to it:**
   ```bash
   git remote set-url origin https://github.com/<your-org>/piq-databricks-platform.git
   git push -u origin main
   ```
   Replace `<your-org>` with your GitHub username or organisation name.

   **c. Create the `platform` GitHub Environment:**
   - On GitHub, open the repo → **Settings** → **Environments** → **New environment**.
   - Name it exactly `platform` (case-sensitive — this is what the CI workflows reference).
   - Under **Deployment protection rules**, tick **Required reviewers** and add yourself.
   - Under **Deployment branches and tags**, select **Selected branches** and add `main`.
   - Save.

   > **What this does:** The CI `apply` workflow targets the `platform` environment.
   > GitHub will pause the workflow and ask for your manual approval before it runs
   > `terraform apply` against production resources. This prevents accidental changes
   > from a bad commit sneaking straight into apply.

6. Fill in `config/platform.yaml` with your real values. Open the file and replace
   the placeholder values for these fields:

   | Field | Where to get it |
   |---|---|
   | `azure.tenant_id` | Azure portal → search "Tenant properties" → **Tenant ID**. Or run `az account show --query tenantId -o tsv` |
   | `azure.subscription_id` | Azure portal → your subscription overview → **Subscription ID**. Or run `az account show --query id -o tsv`. Yours is `b821d55b-210b-495c-a345-d2ab5775ad4b` |
   | `azure.location` | The Azure region where your workspaces will live. Use `eastus2` unless you have a reason to change it (it has the broadest Databricks serverless support). |
   | `unique_suffix` | Pick any 3–6 lowercase alphanumeric string (e.g. `a1b2`). This is appended to globally-unique resource names like the storage account to avoid name collisions across all Azure customers. |
   | `state.storage_account` | Must be 3–24 lowercase alphanumerics, globally unique across all Azure. Convention: `st` + your prefix + `tfstate` + your suffix, e.g. `stpiqtfstatea1b2`. You are choosing a name here — the bootstrap step will create this storage account. |
   | `github.org` | Your GitHub username or organisation name, exactly as it appears in your GitHub URLs (e.g. `avenugopal` or `premiumiq`). |
   | `notifications.ops_email` | An email address for budget and alert notifications. Use your own for now. |
   | `databricks.account_id` | Leave as `00000000-0000-0000-0000-000000000000` for now. You fill this in during Phase 4, after the workspaces exist. |

   > **Tip:** the prefix `piq` and the suffix `a1b2` are already in the file as examples.
   > You can keep them or change them — just keep `prefix` to 2–5 lowercase letters.

**Verify:** `python3 scripts/validate_config.py` prints `Config OK`.

## Phase 2: Bootstrap (local Terraform, once)

> **What this phase does:** creates three things in Azure/Entra:
> 1. A **storage account + container** to hold all future Terraform state files remotely
>    (so CI and your local machine share the same state).
> 2. A **service principal** (`sp-piq-terraform`) — the identity Terraform uses in CI.
>    No passwords: it authenticates via GitHub OIDC (a trust relationship).
> 3. **Role assignments** so that SP can manage resources in your subscription.
>
> Bootstrap itself runs locally (as you, not the SP) because the SP doesn't exist yet.
> Its own state file stays on your machine (`bootstrap/terraform.tfstate`).

```bash
cd bootstrap
terraform init
terraform plan -out tfplan       # expect ~15 resources
terraform apply tfplan
terraform output github_variables
```

> **What `terraform init` does:** downloads the provider plugins (azurerm, azuread)
> into a local `.terraform/` directory. Safe to run repeatedly.
>
> **What `terraform plan` does:** compares the desired state (the `.tf` files) against
> what currently exists in Azure, and prints a list of changes it *would* make.
> It does not change anything. Always review the plan before applying.
>
> **What `terraform apply` does:** executes the plan — creates/updates/deletes
> resources in Azure to match the `.tf` files.

**You do not need to give the SP a password or manually grant it access to GitHub.**
The bootstrap Terraform sets up **OIDC (OpenID Connect)** — a password-free trust
relationship between GitHub Actions and Azure. Here is how it works:

- Bootstrap creates `sp-piq-terraform` in Azure (a service principal — think of it
  as a robot account).
- It also tells Azure: "trust any GitHub Actions job that runs from the
  `anilvenugopal/piq-databricks-platform` repository's `platform` environment or a
  pull request." This trust is the two **federated credentials** you will see on the
  SP after bootstrap runs.
- When a CI job runs, GitHub gives it a short-lived token. The job presents that
  token to Azure, Azure checks the trust rules, and grants the SP's permissions for
  that job only. No password is ever stored anywhere.

The three values printed by `terraform output github_variables` tell the CI workflow
*which* SP to authenticate as. Add them as GitHub **repository variables**
(repo → Settings → Secrets and variables → Actions → **Variables** tab →
New repository variable): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`. Use the **Variables** tab, not Secrets — these are
non-sensitive IDs, not passwords.

**Back up `bootstrap/terraform.tfstate`.** This file lives on your laptop and is
git-ignored (never committed). It is the only record Terraform has of the bootstrap
resources it created. If you lose it, Terraform will think those resources don't
exist and try to create duplicates. Copy it somewhere safe — a personal OneDrive
folder is fine for now.

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

Read the plan: 14 catalogs (vault, three domains and platform/sandbox per
environment, plus `prd_exec_reporting` and `prd_claims_anon`), about 74
schemas, governed tags, grants and bindings.

```bash
./scripts/tf.sh 40-unity-catalog apply tfplan
```

**Verify** (dev workspace SQL editor, as yourself):
```sql
SHOW CATALOGS;                                  -- dev_* catalogs and prd_claims_anon only
SHOW SCHEMAS IN dev_claims;                     -- private schemas plus product_loss
SHOW GRANTS ON SCHEMA dev_claims.product_loss;  -- piq-dev-product-loss has SELECT
SHOW GRANTS ON CATALOG dev_claims;              -- product groups: USE CATALOG only
```

## Phase 7: Workspace configuration (CI)

```bash
./scripts/tf.sh 50-workspace init && ./scripts/tf.sh 50-workspace plan -out tfplan && ./scripts/tf.sh 50-workspace apply tfplan
./scripts/tf.sh 55-ai-platform init && ./scripts/tf.sh 55-ai-platform plan -out tfplan && ./scripts/tf.sh 55-ai-platform apply tfplan
```

**Verify:** SQL Warehouses shows `piq-claims-transform`, `piq-policy-financial-transform`,
`piq-profitability-transform`, `piq-vault-load` and `piq-shared` in both
workspaces, and `piq-exec-reporting-bi` in prd only. As `test.analyst`, only
the three domain warehouses are usable. Personal access tokens are unavailable.

## Phase 8: Governance and observability (CI)

Stacks 60 and 70 run SQL through `scripts/run_sql.py` on `piq-shared`, so the
runner needs Python with `databricks-sdk` (CI installs it).

```bash
./scripts/tf.sh 60-governance init && ./scripts/tf.sh 60-governance plan -out tfplan && ./scripts/tf.sh 60-governance apply tfplan
./scripts/tf.sh 70-observability init && ./scripts/tf.sh 70-observability plan -out tfplan && ./scripts/tf.sh 70-observability apply tfplan
```

**Verify:**
```sql
SHOW FUNCTIONS IN dev_platform.governance;   -- mask_ssn, mask_dob, mask_email, mask_phone, mask_name, mask_amount
SHOW POLICIES ON CATALOG dev_claims;         -- six mask_* policies
SELECT * FROM prd_platform.governance.products;   -- in prd: loss, earned_premium, loss_ratio
```

## Phase 9: Prove the access design

Run `sql/labs/lab06_masking_test.sql` (dev) and `sql/labs/lab11_products.sql` (prd).

| Check | Expected |
|---|---|
| Producer reads a tagged table | masked values (only SARs and writers are exempt) |
| Producer after joining the `claimant_pii` SAR | clear values |
| Analyst reads `dev_vault.landing` | `PERMISSION_DENIED` |
| Any user references `prd_claims` from dev | catalog not accessible |
| `test.executive` lists `prd_profitability` | only `product_loss_ratio` |
| `test.executive` lists `prd_claims` | no schemas (not approved for Loss) |
| `prd_platform.audit.denied_requests` | shows the refused attempts |

## Phase 10: Day-2 readiness

1. Wire the access portal to `.github/workflows/provision-access.yml` (the Worker
   writes the `<!-- piq-access {...} -->` block into the issue body).
2. Turn on branch protection: require PR reviews and Code Owner review on `main`.
3. Practise each procedure in [OPERATIONS.md](OPERATIONS.md) once.
4. After a week, review `prd_platform.monitoring.cost_untagged_usage` and the
   serverless egress denial logs, then set prd `enforcement_mode: ENFORCED`.
