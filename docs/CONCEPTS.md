# Concepts: what each stack does and why

This document explains what Terraform is doing in plain terms, what Databricks
concepts are involved, and why the stacks are structured the way they are.
Read it alongside the RUNBOOK — the RUNBOOK tells you *what to run*, this tells
you *what is happening*.

---

## Terraform basics

**What Terraform is:** a tool that lets you describe infrastructure in code (`.tf`
files) and then creates, updates or deletes real cloud resources to match that
description. Instead of clicking through Azure portal screens, you write what you
want and Terraform figures out the steps.

**State file:** Terraform keeps a file (`.tfstate`) that records what it has already
created. On each run it compares the `.tf` files (desired state) against the state
file (known actual state) and calculates the minimum changes needed. This is why
`plan` shows you a diff, not a full list of everything.

**Remote state:** after bootstrap, all state files are stored in an Azure Storage
container instead of on your laptop. This means CI (GitHub Actions) and your local
machine share the same view of what exists. Each stack has its own state file,
e.g. `10-foundation.tfstate`.

**`terraform_remote_state`:** later stacks need to know things that earlier stacks
created — for example, the workspace URL. They read it using `terraform_remote_state`,
which fetches the output values from a prior stack's state file. This is why the
stacks must run in order.

**Providers:** Terraform talks to cloud APIs through plugins called providers.
This repo uses three: `azurerm` (Azure resources), `azuread` (Entra ID / Azure
Active Directory), and `databricks` (Databricks API).

---

## Deployment tooling

Three Python scripts wrap the raw Terraform workflow and add validation and
auditing. They are the recommended way to apply stacks.

**`scripts/plan.py <stack>`** runs `terraform plan` and writes the plan file to
`stacks/<stack>/tfplan`. Use it to review what would change before committing to
an apply. It makes no changes.

**`scripts/apply.py <stack>`** is the full apply workflow: it calls plan, shows
you the diff, asks for confirmation (or skips it with `--yes` for CI), runs
`terraform apply`, then immediately runs the stack's validation checks. If checks
pass it writes a success record to `audit/runs.jsonl`. If they fail it writes a
failure record and exits non-zero. The audit log gives you a timestamped history
of every apply and its outcome.

**`scripts/check.py <stack>`** runs only the validation checks for a stack that
is already deployed. Useful after a config change to confirm nothing drifted, or
in CI as a scheduled health check.

**`util/`** is the Python package that these scripts and the per-stack checks
share. It has two modules:

- `util/config_reader.py` — reads `config/` YAML and derives expected names
  (groups, catalogs, warehouses) using the same rules as the naming module. Checks
  use this so they automatically stay correct when you add domains, SARs or
  consumers to config.
- `util/validation.py` — the `CheckResult` type (`PASS` / `FAIL` / `RETRY`) and
  the retry runner. A check returning `RETRY` means a known transient condition —
  the runner waits 15 seconds and tries again, up to 5 times, before converting it
  to a `FAIL`. This handles AIM sync delays and other eventual-consistency issues
  without human intervention.

Each stack has its own `stacks/<n>/checks.py` that defines a `CHECKS` list.
Every function in that list receives the stack's Terraform outputs as a dict and
returns a `CheckResult`. Adding a new check to a stack is one function.

---

## The naming module

Before any stack does anything, it calls `module "naming"`. This module reads every
YAML file in `config/` and derives every name, group, grant, catalog, schema and
warehouse from them. It creates nothing — it is pure computation. Every stack uses
its outputs so that a group name or catalog name is spelled the same way everywhere.

If you change something in `config/`, re-running any stack will pick it up because
the naming module is re-evaluated every time.

---

## Bootstrap (run once, locally)

**What it creates:**
- A **storage account** in Azure (`stpiqtfstate...`) with a container called `tfstate`.
  This is where all future state files live.
- An **Entra app + service principal** called `sp-piq-terraform`. Think of this as a
  robot account that Terraform uses in CI.
- **Role assignments** giving that SP permission to create resources and manage
  role assignments in your Azure subscription.
- **OIDC federated credentials** — a trust rule that says "when a GitHub Actions job
  runs from this repo's `platform` environment, it may act as `sp-piq-terraform`
  without a password."

**Why it runs locally:** the SP doesn't exist yet, so CI can't run. You run it once
as yourself (your `az login` session), then hand off to CI.

---

## Stack 10-foundation — Azure infrastructure

**What it creates:**

| Resource | Purpose |
|---|---|
| Resource group (`rg-piq-dev`, `rg-piq-prd`) | A container that holds all Azure resources for one environment |
| Virtual network + subnets | The private network Databricks cluster nodes run inside. Two subnets per workspace: "host" (where nodes live) and "container" (internal Databricks traffic) |
| Databricks workspace (`dbw-piq-dev`, `dbw-piq-prd`) | The actual Databricks workspace. Premium tier enables Unity Catalog and serverless compute |
| Storage account (`stpiqdev...`, `stpiqprd...`) | ADLS Gen2 — Azure's data lake storage. Unity Catalog stores all table data here, one storage container per catalog |
| Access Connector (`ac-piq-dev`, `ac-piq-prd`) | A managed identity that Unity Catalog uses to read/write the storage account. No passwords — Azure handles auth internally |
| Key Vault | For any secrets that can't use OIDC (currently reserved for future use) |

**Why VNet injection?** By default, Databricks runs cluster nodes on Microsoft's
network. VNet injection puts them inside your own Azure Virtual Network, so you
control network access, firewall rules, and private connectivity to other Azure
services. It also means no public IPs on cluster nodes.

**Side effect:** creating the first Premium workspace automatically creates your
Databricks *account* — the account-level console at
`https://accounts.azuredatabricks.net`.

---

## Stack 20-identity — Entra groups and service principals

**What it creates:**

| Resource | Purpose |
|---|---|
| Entra security groups (`piq-dev-claims-producer`, etc.) | One group per environment × domain × role. These become the access control principals for everything in Databricks |
| Group nesting | Personas are nested into role groups; consumer groups are nested into product groups; SAR groups contain the groups that have unlocked them |
| Per-domain service principals (`sp-piq-dev-claims-deploy`, etc.) | The robot account for each domain's CI pipeline. Each one has an OIDC trust for its domain's GitHub repo |
| Vault loader SP | The identity that writes to the shared raw vault |
| Test users | Training-only Entra users (test.analyst, test.engineer, etc.) with auto-generated passwords |

**Key concept — Entra as the source of truth for identity:** all groups live in
Microsoft Entra ID (formerly Azure Active Directory). Databricks does not maintain
its own copy — it reads from Entra automatically via **Automatic Identity Management
(AIM)**. This is why, after stack 20 runs, you see those groups appear in the
Databricks account console with the "In Microsoft Entra ID" label.

**Key concept — AIM sync delay:** AIM does not propagate group membership
instantaneously. After stack 20 applies and Entra group memberships change, allow
roughly one minute before running stacks that depend on those memberships (stack 30,
stack 50). If a stack fails with a "user does not have permission" error immediately
after stack 20, wait a minute and retry.

**Key concept — the platform-admin persona and the `system` catalog:** stack 50
grants `piq-platform-monitoring` the ability to read Databricks system tables (audit
logs, query history, cost records). That grant requires MANAGE on the `system`
catalog, which only metastore admins have. The stacks run locally as your personal
`az login` session, so *you* need to be a metastore admin when stack 50 runs.

Metastore admin is held by the group `piq-metastore-admins`. You get into that group
by being in the `platform-admin` persona, which is nested into `piq-metastore-admins`.
The persona is defined in `config/personas.yaml` — add your **UPN** (User Principal
Name) to its `members` list before applying stack 20.

**What a UPN is:** the login name of a user in Microsoft Entra ID. It looks like an
email address (`you@yourdomain.com`) and is unique across your tenant. It is the
value you used when you first signed in to Azure. You can confirm yours with:
```bash
az ad signed-in-user show --query userPrincipalName -o tsv
```

**Key concept — OIDC for domain SPs:** just like the Terraform SP, each domain
deployer SP has no password. Its CI pipeline authenticates by presenting a
GitHub-issued token, and Azure checks whether the token matches the trust rule for
that repo and environment.

---

## Stack 30-account — Databricks account configuration

This stack operates at the **Databricks account level**, not inside any workspace.
The account is the parent of all workspaces and is where cross-workspace things live.

**What it creates:**

| Resource | Purpose |
|---|---|
| AIM resolution | Reads each Entra group/SP into the Databricks account so it can be referenced in later stacks. This is the step that formally registers identities with Databricks |
| Workspace assignments | Adds groups and SPs to the dev or prd workspace with USER or ADMIN permission |
| Serverless usage policies | Tags every serverless DBU (Databricks Unit — the billing unit for compute) with `piq_env` and `piq_domain`. This is how you know which domain incurred which cost |
| Budgets | Alert-only cost budgets per environment and per domain. They email `ops_email` when spending crosses 50/80/100% of the monthly limit. They do not cut off compute |
| Egress network policies | Controls which external URLs serverless compute can reach. Starts in `DRY_RUN` (logs violations but doesn't block) so you can see what your code actually calls before enforcing |

**Why a separate account stack?** Workspace assignments and usage policies are
account-level Databricks API calls — they don't exist inside a workspace. Keeping
them in their own stack makes it clear what requires account-admin credentials vs.
workspace-admin credentials.

---

## Stack 40-unity-catalog — catalogs, schemas, grants and tags

Unity Catalog is Databricks' central governance layer — a single place to manage
all data assets (tables, views, volumes, models) across all workspaces, with
fine-grained access control.

**Three-level namespace:** everything in Unity Catalog lives at
`catalog.schema.table`. A catalog is like a database-of-databases; a schema
(also called a database) groups related tables.

**What it creates:**

| Resource | Purpose |
|---|---|
| Catalogs | One per environment × domain (`dev_claims`, `prd_claims`), plus vault, consumer prep, anonymized, platform and sandbox catalogs |
| Storage bindings | Links each catalog to its storage container in the ADLS Gen2 account |
| Schemas | Private domain schemas (business_vault, info_mart, etc.), product schemas (`product_loss`), vault schemas (landing, raw_vault, stage_*), platform schemas |
| Grants | Which group gets which privilege on each catalog and schema. Derived entirely from `config/access_matrix.yaml` |
| Governed tags | A tag taxonomy enforced by Databricks (e.g. `pii`, `sensitive_metric`). Only authorised groups can apply these tags. Tags drive column masking in stack 60 |
| ABAC policy definitions | Declares which mask function applies to which tag value on which catalog. Stack 60 activates them |

**Key rule — product isolation:** a product group gets `USE CATALOG` but not
`BROWSE` on a domain catalog. This means a consumer can query their approved product
schema but cannot list or discover other schemas in that catalog.

**Key rule — no environment in schema names:** schemas are named `product_loss`,
not `dev_product_loss`. The same dbt model runs in dev and prd unchanged.

---

## Stack 50-workspace — warehouses and compute policies

**What it creates inside each workspace:**

| Resource | Purpose |
|---|---|
| SQL Warehouses | Serverless SQL compute endpoints. One per domain (`piq-claims-transform`), one for the vault loader (`piq-vault-load`), one per consumer domain (`piq-exec-reporting-bi` in prd only), one shared (`piq-shared`) |
| Compute policies | Cluster policies that restrict what kinds of clusters domain users can create (size limits, auto-termination, required tags) |
| IP access lists | If configured in `platform.yaml`, restricts workspace login to specific CIDRs |
| System table access | Enables Databricks system tables (audit logs, query history, cost data) that stack 70 will query |

**What a SQL warehouse is:** a pool of serverless compute that runs SQL queries.
It scales up when queries arrive and scales to zero when idle — you only pay while
it's running queries. Each domain has its own warehouse so costs are attributed
correctly and one domain's heavy query load doesn't affect another.

---

## Stack 55-ai-platform — AI infrastructure

**What it creates:**

| Resource | Purpose |
|---|---|
| App Spaces | Databricks Apps hosting environment — for domains with `app_space: true` in `domains.yaml` |
| Vector search endpoints | For domains using embeddings and semantic search |
| Lakebase | For domains with `lakebase: true` — a managed Postgres-compatible database backed by the lakehouse |

These are optional per-domain features controlled by flags in `config/domains.yaml`.

---

## Stack 60-governance — column masking

**What it creates:**

| Resource | Purpose |
|---|---|
| Masking SQL functions | SQL functions like `mask_ssn()`, `mask_dob()` stored in `{env}_platform.governance`. They return a redacted value (e.g. `***-**-1234`) unless the caller is in an exempt group |
| ABAC column mask policies | Attaches each masking function to each catalog, triggered by governed tags. For example: any column tagged `pii=ssn` in `prd_claims` is automatically masked for everyone except the `claimant_pii` SAR group and the claims writer SP |

**How masking works end to end:**
1. A data engineer tags a column: `ALTER TABLE ... SET TAGS ('pii' = 'ssn')`
2. Stack 60 has already applied a policy: "on catalog `prd_claims`, mask any column
   where `has_tag_value('pii', 'ssn')` using `mask_ssn()`, except for SAR group
   `piq-prd-sar-claimant-pii` and the claims writer SP"
3. A producer analyst queries that column — they see `***-**-1234`
4. The same analyst joins the `claimant_pii` SAR (via a PR to `config/sars.yaml`
   approved by governance) — they now see the real value

Nobody writes custom per-table access rules. The masking follows the tag automatically
across every column in every table in that catalog.

---

## Stack 70-observability — monitoring views

**What it creates:**

SQL views in `prd_platform` over Databricks system tables. System tables are
Databricks-managed tables that record everything that happens in your account:
every query, every job run, every permission change, every cost record.

| View | What it shows |
|---|---|
| `monitoring.cost_daily_by_env_domain` | Daily spend broken down by environment and domain tag |
| `monitoring.cost_untagged_usage` | Compute that ran without `piq_domain` tags — a signal that something bypassed the usage policies |
| `audit.denied_requests` | Permission-denied events — who tried to access what and was refused |
| `audit.permission_changes` | Every grant and revoke |
| `governance.pii_columns` | All columns currently tagged with PII tags |
| `governance.lineage_recent` | Data lineage — which tables read from which other tables |
| `governance.products` | The published product catalog |
| `observability.query_activity_daily` | Query volume and latency by warehouse |
| `observability.job_run_outcomes` | Job success/failure rates |

These views are created by running SQL files through the Databricks Statement
Execution API (via `scripts/run_sql.py`). Terraform re-runs the SQL whenever the
file changes.
