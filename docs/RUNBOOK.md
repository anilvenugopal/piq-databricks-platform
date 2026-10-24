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
   ```bash
   pip install -r requirements.txt
   ```
   > This installs `pyyaml`, `ruamel.yaml`, `databricks-sdk`, and the repo's own
   > `util` package in editable mode (`-e .`). The `util` package is used by
   > `scripts/plan.py`, `scripts/apply.py`, and `scripts/check.py`. Run this
   > command again after pulling changes that add new files to `util/`.

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
environment. Or locally:

```bash
./scripts/tf.sh 10-foundation init
python3 scripts/apply.py 10-foundation
```

`apply.py` runs plan, asks for confirmation, applies, then runs the foundation
checks (workspace URLs reachable, storage accounts provisioned) and writes an
audit record to `audit/runs.jsonl`.

Workspace creation takes 5–10 minutes each. The first Premium workspace creates
your Databricks account.

**Verify:**
```bash
python3 scripts/check.py 10-foundation
```
Both workspace URLs must be reachable and both storage accounts provisioned.
Also confirm both workspace URLs open in a browser and you can sign in.

## Phase 4: Claim the Databricks account (MANUAL, once)

1. Open `https://accounts.azuredatabricks.net` and sign in as the Global
   Administrator. The first sign-in makes you an **account admin**.
2. Copy the **Account ID** into `config/platform.yaml` (`databricks.account_id`),
   commit and push. The Account ID is shown in the top-right user menu — click your
   name/email in the top-right corner and it appears in the dropdown.
3. **User management** (left sidebar) → **Service principals** tab → **Add service
   principal** → search for `sp-piq-terraform` → select it → **Add**.
   Then open it from the list → **Roles** tab → enable **Account admin**.
4. Apply **stack 20-identity** now (next phase), then return here for step 5.
5. **Catalog** (left sidebar) → select the metastore (there should be one for your
   region) → **Metastore admin** → change it to the group `piq-metastore-admins`
   (this group is created by stack 20, which is why you run that first).

**Verify:** **Workspaces** (left sidebar) lists both `dbw-piq-dev` and `dbw-piq-prd`;
**Catalog** (left sidebar) shows the metastore with admin set to `piq-metastore-admins`.

## Phase 5: Identity and account (CI)

### 5a. Add yourself to the platform-admin persona (MANUAL, before running stack 20)

Before applying stack 20, add your Azure user account to the `platform-admin` persona
in `config/personas.yaml`. This puts you in the `piq-metastore-admins` group, which
is what gives you MANAGE rights on the Unity Catalog `system` catalog. Without this,
stack 50 will fail with `User does not have MANAGE on Catalog 'system'`.

**Why the `system` catalog requires this:** `USE_CATALOG` on `system` can only be
granted by someone with MANAGE on that catalog, which requires metastore admin. Stack
50 grants `piq-platform-monitoring` `USE_CATALOG` on `system` so that stack 70 can
read system tables. The grant runs locally as your `az login` session, so *you*
personally need to be a metastore admin at the time stack 50 runs.

**Your UPN** (the value to add) is the email address you use to log into Azure — the
same one that appears when you run `az ad signed-in-user show`. Confirm it with:

```bash
az ad signed-in-user show --query userPrincipalName -o tsv
```

Open `config/personas.yaml` and find the `platform-admin` persona. Change its
`members` list from `[]` to include your UPN:

```yaml
platform-admin:
  description: Operates the platform (break-glass account admin is separate)
  member_of: ["dev-workspace-admins", "prd-workspace-admins", "metastore-admins"]
  members: ["your-upn@yourdomain.com"]
```

> **What a UPN is:** User Principal Name — Microsoft's term for the login name of a
> user in Entra ID. It looks like an email address and is unique across your tenant.
> Stack 20 uses it to look up your Entra user object and add it to the persona group.

Commit and push this change before running stack 20.

### 5b. Apply stack 20 and complete Phase 4 step 5

```bash
./scripts/tf.sh 20-identity init
python3 scripts/apply.py 20-identity
# Phase 4 step 5 now, then:
./scripts/tf.sh 30-account init
python3 scripts/apply.py 30-account
```

After stack 20 applies, wait approximately one minute before running stack 30 or
stack 50. Automatic Identity Management (AIM) syncs your Entra group memberships
into Databricks on a short delay. The stack 20 and stack 30 checks have RETRY
logic for AIM-dependent assertions — they will wait and recheck automatically.

Get test-user passwords (training only):
```bash
./scripts/tf.sh 20-identity output -json test_user_credentials
```

**Verify:**
```bash
python3 scripts/check.py 20-identity
python3 scripts/check.py 30-account
```
Stack 20 checks: all expected Entra groups present, Terraform SP has OIDC
credentials, platform-admin persona has members.
Stack 30 checks: usage policies exist for every env:domain, key groups assigned
to prd workspace.

---

## Running stacks as sp-piq-terraform (after Phase 4)

After Phase 4, `sp-piq-terraform` is an account admin in Databricks and a member
of `piq-metastore-admins`. It has all the privileges the platform stacks need. CI
always runs as this SP. You can also run locally as the SP when you need to test
exactly what CI will do — for example to reproduce a CI failure, or to apply a stack
without using your own personal credentials.

**When this is possible:** only after Phase 4 step 3 (the SP is added as Databricks
account admin) and after stack 20 has run (the SP is added to `piq-metastore-admins`
in Entra). Before that, the SP lacks the Unity Catalog rights that later stacks need.

**How to do it:** the SP was created with OIDC only — no client secret. To log in
locally you need to create a temporary client secret in Entra.

1. Find the SP's app registration:
   ```bash
   az ad app list --display-name "sp-piq-terraform" --query "[0].appId" -o tsv
   ```

2. Create a temporary secret (it will be shown once — save it):
   ```bash
   az ad app credential reset --id <appId-from-step-1> --append \
     --display-name "local-dev-temp" --years 1
   ```
   This prints `appId`, `password` (the secret), and `tenant`.

3. Log in as the SP:
   ```bash
   az login --service-principal \
     --username <appId> \
     --password <password> \
     --tenant <tenantId>
   ```

4. Run the stack as normal:
   ```bash
   python3 scripts/apply.py 50-workspace --yes
   ```
   Or using the low-level wrapper:
   ```bash
   ./scripts/tf.sh 50-workspace plan -out tfplan
   ./scripts/tf.sh 50-workspace apply tfplan
   ```

5. **Clean up the secret when done** — the SP is normally passwordless and the
   secret is a security downgrade. Delete it from the Azure portal:
   Entra → App registrations → `sp-piq-terraform` → **Certificates & secrets** →
   find `local-dev-temp` → delete it.
   Or via CLI:
   ```bash
   # List credential key IDs to find the one to delete
   az ad app credential list --id <appId> --query "[].{name:displayName, keyId:keyId}"
   # Delete by key ID
   az ad app credential delete --id <appId> --key-id <keyId>
   ```

> **Note:** creating a client secret does not affect the existing OIDC federated
> credentials that CI uses. They are separate. Deleting the temp secret after use
> returns the SP to its passwordless state without touching CI.

---

## Phase 6: Unity Catalog (CI)

```bash
./scripts/tf.sh 40-unity-catalog init
python3 scripts/apply.py 40-unity-catalog
```

The plan covers 14 catalogs (vault, three domains and platform/sandbox per
environment, plus `prd_exec_reporting` and `prd_claims_anon`), about 74
schemas, governed tags, grants and bindings. Review the plan diff before
confirming.

**Verify:**
```bash
python3 scripts/check.py 40-unity-catalog
```
Checks that all expected catalogs exist and that producer groups have
USE_CATALOG on each domain catalog.

Also verify in the dev workspace SQL editor:
```sql
SHOW CATALOGS;                                  -- dev_* catalogs and prd_claims_anon only
SHOW SCHEMAS IN dev_claims;                     -- private schemas plus product_loss
SHOW GRANTS ON SCHEMA dev_claims.product_loss;  -- piq-dev-product-loss has SELECT
SHOW GRANTS ON CATALOG dev_claims;              -- product groups: USE CATALOG only
```

## Phase 7: Workspace configuration (CI)

```bash
./scripts/tf.sh 50-workspace init
python3 scripts/apply.py 50-workspace
./scripts/tf.sh 55-ai-platform init
python3 scripts/apply.py 55-ai-platform
```

> **Note on stack 55:** some AI platform features (App Spaces, Lakebase) are in
> private preview and may fail depending on your account's access. Stack 55 is
> safe to skip for the initial build — stacks 60 and 70 do not depend on it.

**Verify:**
```bash
python3 scripts/check.py 50-workspace
```
Checks that all warehouses exist in both workspaces and that the monitoring
group has USE_CATALOG on the system catalog.

Also confirm in the workspace UI: SQL Warehouses shows `piq-claims-transform`,
`piq-policy-financial-transform`, `piq-profitability-transform`, `piq-vault-load`
and `piq-shared` in both workspaces, and `piq-exec-reporting-bi` in prd only.
As `test.analyst`, only the three domain warehouses are usable. Personal access
tokens are unavailable.

## Phase 8: Governance and observability (CI)

Stacks 60 and 70 run SQL through `scripts/run_sql.py` on `piq-shared`. The
`databricks-sdk` required for this is installed by `pip install -r requirements.txt`.

```bash
./scripts/tf.sh 60-governance init
python3 scripts/apply.py 60-governance
./scripts/tf.sh 70-observability init
python3 scripts/apply.py 70-observability
```

**Verify** (SQL editor in either workspace):
```sql
SHOW FUNCTIONS IN dev_platform.governance;        -- mask_ssn, mask_dob, mask_email, mask_phone, mask_name, mask_amount
SHOW POLICIES ON CATALOG dev_claims;              -- six mask_* policies
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
