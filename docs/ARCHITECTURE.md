# Architecture

This document describes what the platform is and why each choice was made. For
the steps to build it, see [RUNBOOK.md](RUNBOOK.md).

## 1. Topology

```
Microsoft Entra ID ──(automatic identity management)──┐
   users, groups, service principals                   │
                                                       ▼
GitHub Actions ──(OIDC)──> sp-piq-terraform ──> Databricks account
                                                 ├─ Unity Catalog metastore (one per region)
                                                 ├─ piq-dev workspace ── dev_* catalogs ── ADLS dev
                                                 └─ piq-prd workspace ── prd_* catalogs ── ADLS prd
```

| Plane | Lives in | Holds |
|---|---|---|
| Control plane | Databricks' Azure subscription | UI, APIs, job scheduler, Unity Catalog metadata |
| Classic compute plane | Your VNet (`vnet-piq-<env>`) | Cluster VMs, only when classic compute is used |
| Serverless compute plane | Databricks-managed, same region | SQL warehouses, serverless jobs/pipelines, apps, model serving |
| Data | Your storage accounts | Every managed table, volume and file |

The account is created implicitly by the first Premium workspace in your Entra
tenant. The regional metastore is created and assigned automatically.

## 2. Environments and workspaces

Two workspaces, one per environment. Domains are **catalogs**, not workspaces:
one platform team serves several domains, so a workspace per domain would multiply
admin overhead without adding isolation that catalogs and bindings don't already
give. Add `stg` later by extending `config/platform.yaml` and the two
per-environment module calls in stacks 40, 50, 55 and 60.

Workspaces use VNet injection with secure cluster connectivity (no public IPs on
cluster nodes). Networking cannot be changed cheaply after creation, so it is set
from day one even though most compute is serverless.

## 3. Catalogs, schemas, storage

| Catalog | Bound to | Contains |
|---|---|---|
| `{env}_{domain}` | `{env}` workspace | `bronze`, `staging`, `silver`, `gold`, `marts`, `ref`, `audit`, `ai` schemas; `bronze.landing` and `bronze.documents` volumes |
| `dev_sandbox` | dev | `u_<user>` personal schemas from `config/sandbox_users.yaml` |
| `prd_sandbox` | prd | `exp_<name>` approved experiments from `config/experiments.yaml` |
| `{env}_platform` | `{env}` | `governance` (masking functions), `audit`, `monitoring`, `observability` views (prd) |

Storage chain for each catalog:

```
access connector ac-piq-<env> (Azure managed identity, Storage Blob Data Contributor)
  -> storage credential <env>_lake_credential      (ISOLATED to the env workspace)
  -> external location  <catalog>_root             (abfss://<container>@st...<env>.../)
  -> catalog managed location
```

Users hold **no** storage permissions. When a query runs, Unity Catalog checks
grants and vends short-lived credentials scoped to the exact paths needed.
Credentials, external locations and catalogs are all created `ISOLATED` through
their environment's workspace, so the dev workspace cannot use prd storage paths
even through an external table.

## 4. Identity

All identities live in Entra ID and are managed by stack 20 (`azuread` provider).
Automatic identity management (AIM) makes them visible in Databricks; stack 30
resolves each into the account with the `databricks_account_iam_external_*_v2`
data sources and assigns them to workspaces.

| Group type | Name pattern | Count (3 domains) | Purpose |
|---|---|---|---|
| Functional | `piq-{env}-{domain}-{role}` | 36 | What receives Unity Catalog grants |
| Persona | `piq-persona-{name}` | 8 | What people join; nested into functional/platform groups |
| Platform | `piq-{name}` | 8 | Admin scopes, monitoring, sandboxes |

Roles: `producer`, `consumer`, `analyst`, `admin`, `ai`, `dbadmin`.

Persona nesting reproduces the Snowflake persona table: a data engineer joins
`piq-persona-data-engineer`, which is a member of `piq-dev-*-producer`,
`piq-prd-*-analyst` and `piq-sandbox-users`.

**Admin scopes (separation of duties):**

| Scope | Group | Can |
|---|---|---|
| Account admin | `piq-account-admins` + Terraform SP | Workspaces, identity, budgets, account settings. Break-glass for humans |
| Metastore admin | `piq-metastore-admins` (contains Terraform SP) | Top-level Unity Catalog objects |
| Workspace admin | `piq-{env}-workspace-admins` | Compute and settings in one workspace |
| Governance admin | `piq-governance-admins` | Tag policies, masking functions, ABAC policies (via CODEOWNERS review) |
| Monitoring | `piq-platform-monitoring` | Read system tables and platform views |

**Service principals** (`config/service_principals.yaml`): `sp-piq-dev-deploy`,
`sp-piq-prd-deploy`, `sp-piq-powerbi`, `sp-piq-monitoring`, plus
`sp-piq-terraform` from bootstrap. CI authenticates with GitHub OIDC federated
credentials scoped to `repo:<org>/<repo>:environment:<env>`. No client secrets.

## 5. Access model

`config/access_matrix.yaml` is your Snowflake LAYER x ROLE matrix. The naming
module expands it into `databricks_grants` at schema level, plus catalog-level
`USE_CATALOG` + `BROWSE` for every role and `ALL_PRIVILEGES` + `MANAGE` for
`dbadmin`.

Snowflake access roles (`_R`, `_RW`, `_RWC`) become **privilege bundles** rather
than objects. In Unity Catalog, privileges inherit down the catalog → schema →
object tree and are granted straight to groups, so an intermediate role layer adds
indirection without adding control.

| Bundle | Privileges |
|---|---|
| R | `USE_SCHEMA`, `SELECT`, `EXECUTE`, `READ_VOLUME` |
| RW | R + `MODIFY`, `WRITE_VOLUME` |
| RWC | RW + `CREATE_TABLE`, `CREATE_MATERIALIZED_VIEW`, `CREATE_FUNCTION`, `CREATE_VOLUME`, `CREATE_MODEL` |

Catalogs are owned by the Terraform SP, never a person, so ownership cannot drift.
Grants are authoritative: anything granted outside Terraform is removed on the
next apply of stack 40.

**Workspace objects are a second permission plane.** SQL warehouses, compute
policies and vector search endpoints have their own ACLs, set from
`config/workspace_objects.yaml` in stacks 50 and 55. A table grant does not let
anyone run a warehouse.

## 6. Governance

- **Governed tags** (`config/governed_tags.yaml`): `piq_env`, `piq_domain`,
  `piq_layer`, `piq_sensitivity`, `pii`, `piq_ai_approved`, `piq_owner`, each with
  allowed values and a list of who may assign it. Catalogs get env/domain tags and
  schemas get layer tags automatically.
- **ABAC column masks** (stack 60): for every data catalog and every `pii` value,
  one policy `ON CATALOG ... COLUMN MASK <env>_platform.governance.mask_<type>
  TO account users EXCEPT <producer, admin, dbadmin of that domain> MATCH COLUMNS
  has_tag_value('pii','<type>')`. Tagging a column is all a producer has to do.
- **Data classification** scans data catalogs and proposes `class.*` system tags.
  Review findings, then apply the governed `pii` tag that drives masking.
- **Tagging is a security boundary.** Whoever can set `pii` decides what is
  masked; assigners are restricted per tag and the tag config is CODEOWNERS-protected.

Masks apply to tables, materialized views and streaming tables. They do **not**
apply inside files in volumes; see section 9.

## 7. Compute and cost

| Snowflake construct | Here |
|---|---|
| 16 domain warehouses | Two serverless warehouses per env (`piq-<env>-etl`, `piq-<env>-bi`), auto-stop 10 min |
| Resource monitors | Budgets (alert-only) + warehouse auto-stop + compute policies |
| Query tags | Serverless usage policies, warehouse/cluster custom tags |

Attribution: every env x domain has a **serverless usage policy** carrying
`piq_env` and `piq_domain` tags; the domain's groups and service principals are
its users. Warehouses carry `piq_env` and `piq_workload`. Compute policies force
`piq_env` and require `piq_domain` on any classic cluster.
`prd_platform.monitoring.cost_untagged_usage` shows anything that escaped.

Budgets notify at 75/90/100% and never stop compute. That matches your
alert-only `RM_PRD_TRANSFORM`; for hard ceilings rely on auto-stop, max cluster
counts, compute policy limits and statement timeouts.

## 8. Network and security

| Control | Where | Default |
|---|---|---|
| VNet injection, no public IPs | 10-foundation | on |
| NAT gateway for classic egress | `platform.yaml` `nat_gateway` | off (classic clusters cannot reach the internet) |
| Workspace IP access lists | `platform.yaml` `ip_access_list` | empty = not enforced |
| Serverless egress policy | `platform.yaml` `serverless_egress` | dev FULL_ACCESS; prd RESTRICTED in DRY_RUN |
| Personal access tokens | 50-workspace | disabled |
| Storage shared keys | 10-foundation | disabled (Entra auth only) |
| Front-end / back-end Private Link | not yet | later hardening phase |

**IP access lists and GitHub-hosted runners do not mix**: runners come from
thousands of addresses. Enable IP lists only with self-hosted runners in an
allowed range, or keep them off for training.

## 9. AI and apps

The six seams from the design discussion, and how the repo handles each:

| Seam | Handling |
|---|---|
| Two permission planes | `workspace_objects.yaml` + bundle-level permissions |
| App identity | Template defaults to on-behalf-of-user auth; app SPs get only declared resources |
| PII in documents | Raw files in restricted `bronze.documents`; parse to tables; mask there; index only `piq_ai_approved` data |
| Lakebase roles | Postgres roles provisioned by the app's bundle, not by UC grants |
| Promotion | Deploy code, not artifacts: the same bundle goes dev → prd |
| Outbound calls | Unity AI Gateway (budget in stack 30) + serverless egress policies |

Each domain catalog has an `ai` schema for tool functions, models, vector indexes
and evaluation sets. Stack 55 creates one Vector Search endpoint per env and an
App Space per domain with the domain's usage policy.

## 10. Observability

System tables are account-wide, so one set of views in `prd_platform` covers both
environments:

| View | Answers |
|---|---|
| `monitoring.cost_daily_by_env_domain` | What did each env x domain cost, by product |
| `monitoring.cost_untagged_usage` | What escaped attribution, and who ran it |
| `observability.query_activity_daily` | Who runs what on which warehouse |
| `observability.job_run_outcomes` | Which pipelines fail |
| `audit.denied_requests` | Which access attempts were refused |
| `audit.permission_changes` | Who changed access (anything not by Terraform is drift) |
| `governance.pii_columns` | Which columns are masked |
| `governance.lineage_recent` | What feeds what |

## 11. Snowflake → Databricks mapping

| Snowflake (your design) | Databricks (this repo) |
|---|---|
| `{ENV}_INSURANCE` databases | `{env}_{domain}` catalogs bound to env workspaces |
| `PIQ_ADMIN` | `{env}_platform` + system tables |
| `SANDBOX` `U_*` / `EXP_*` via stored procedures | `dev_sandbox.u_*` / `prd_sandbox.exp_*` via YAML + PR |
| Access roles `_R/_RW/_RWC` | Privilege bundles |
| Functional roles (AD-synced) | Entra functional groups via AIM |
| Persona → role assignments | Persona groups nested into functional groups |
| `PIQ_SYSADMIN` / `SECADMIN` / `MASKINGADMIN` / `USERADMIN` | Account / metastore / workspace / governance admins; user admin is Entra |
| Service users + RSA keys | Service principals + OIDC |
| Network policies | IP access lists, VNet injection, egress policies |
| Resource monitors | Budgets + usage policies + compute policies |
| Object tags | Governed tags |
| Masking policies | ABAC column masks |
| schemachange versioned migrations | Terraform desired state + Asset Bundles for workloads |
| `new_tenant.py` | One entry in `config/domains.yaml` |
| Access portal → CREATE USER | Access portal → PR adding Entra membership |
