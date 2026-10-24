# Platform federation: responsibility model and architecture

This document describes the federated architecture of the PremiumIQ Databricks
platform as resolved in CR-001 (2026-10-22). It defines who owns what, how the
platform and domain sides interact, and what each platform stack does in the
federated model.

Read this alongside CONCEPTS.md (Terraform and Databricks fundamentals) and
CR-001 (the change record that established this design).

---

## Responsibility boundary

The platform team owns everything that spans domains: identity, compute, cost
controls, governance and the rules of the mesh. Domains own everything inside
their own catalog: schemas, products, pipelines and data.

| Responsibility | Owner | Mechanism | Platform service |
|---|---|---|---|
| Catalog, storage, bindings | Platform | Platform stack 40 | — |
| Base groups (domain roles, writer, SAR, persona) | Platform | Platform stack 20 | — |
| Deploy service principal + OIDC trust | Platform | Platform stack 20 | — |
| Administrative unit + scoped Group Administrator role | Platform | Platform stack 20 | — |
| Catalog-users group | Platform | Platform stacks 20 + 40 | — |
| Warehouse, usage policy, budget | Platform | Platform stacks 30 + 50 | — |
| Governed tags, masks, Sensitive Access Roles | Platform (governance) | Platform stacks 40 + 60 | — |
| Observability views | Platform | Platform stack 70 | — |
| Group registration in Databricks account | Platform (async) | Scheduled stack 30 | Pattern 3 — see below |
| Central uniqueness / cycle / contract checks | Platform | Scheduled platform workflow | Pattern 2 — see below |
| Private schemas (business_vault, info_mart, etc.) | Domain | Domain Terraform via enabler module | Pattern 1 — see below |
| Product schemas, grants, tags | Domain | Domain Terraform via enabler module | Pattern 1 |
| Product groups (inside administrative unit) | Domain | Domain Terraform via enabler module | Pattern 1 |
| Consumer nesting | Domain | Domain Terraform via enabler module | Pattern 1 |
| Tables, pipelines, jobs | Domain | Domain Asset Bundle | — |
| Column tags on tables | Domain | Domain pipeline (dbt or SQL) | — |
| Consumer group membership | Consumer lead | Directly in Entra | — |

---

## Platform service catalog

There are three patterns by which domains interact with platform-owned services.
Each is used for a different class of operation.

### Pattern 1 — Terraform enabler module (pull, self-service)

The platform publishes a Terraform module in a separate public GitHub repository.
A domain's CI pipeline downloads the module and runs it using the domain's own
deploy identity. The module contains the logic; the domain's credentials execute it.

The domain identity is scoped to its own catalog and administrative unit, so it
cannot act outside its space regardless of what the module contains. The platform
controls the rules through the module code; the domain controls when it runs. Each
domain runs independently — no coordination with the platform team is needed.

**Used for:** private schemas, product schemas, product groups, consumer nesting,
grants and tags — all within the domain's own catalog and administrative unit.

**Not used for:** anything requiring platform-level credentials.

### Pattern 2 — Reusable GitHub Actions workflow (call, platform-controlled logic)

The platform repository publishes reusable workflows that domain pipelines can call
as a step. Crucially, the called workflow runs with the **platform repository's**
credentials, not the domain's. GitHub concurrency groups queue concurrent callers
so the platform stack is never run in parallel by multiple domains simultaneously.

**Used for:** operations triggered synchronously by a domain pipeline that require
platform credentials — central uniqueness and dependency-cycle checks after a
domain publishes a product, and future operations that cross domain boundaries.

**Not used for:** long-running or multi-stack operations, or anything the domain
can do with its own identity.

### Pattern 3 — Scheduled platform stack (async, platform-owned)

Stack 30 runs on a schedule in addition to running on platform config changes. On
each run it scans every domain administrative unit and pulls any new groups into
the Databricks account. Domains create their groups and wait; the delay is bounded
by the schedule interval.

**Used for:** registering domain-created product groups in the Databricks account.
No domain action required; the domain's pipeline does not need to wait or call
anything.

**Not used for:** anything the domain needs to happen synchronously during its
own deployment.

---

## The identity boundary: administrative units

An Entra **administrative unit** is a scoping boundary. A role assigned within an
administrative unit applies only to the objects inside it.

The platform creates one administrative unit per domain per environment:
`au-piq-dev-claims`, `au-piq-prd-claims`, and so on. The domain's deploy service
principal (`sp-piq-dev-claims-deploy`) is given **Groups Administrator scoped to
`au-piq-dev-claims`** — it can create and manage groups inside that unit and is
refused if it touches anything outside it.

Product groups the domain creates live inside the unit. All platform-managed groups
(domain roles, writer, SAR, persona, consumer) live outside it and cannot be
modified by the domain.

The dev and prd units are kept separate so the dev deploy identity can never modify
prd groups.

---

## The catalog boundary: catalog-users group

A domain product group needs `USE CATALOG` on the domain catalog so consumers can
reach its product schema. If the domain could grant catalog-level permissions
directly, every platform apply would revoke them (Terraform is authoritative for
what it manages).

The solution: the platform creates one group per domain catalog called
`piq-{env}-{domain}-catalog-users` and grants it `USE CATALOG` (no `BROWSE`) on
the catalog. This grant is platform-managed and permanent. The domain adds each of
its product groups to `catalog-users` — a group membership operation inside its own
administrative unit, which the domain identity is allowed to do.

Consumers therefore never see private schema names. They can only reach schemas
they have been explicitly nested into through a product group.

---

## What each platform stack does in the federated model

### Bootstrap (run once, locally)

Creates the three things CI needs before it can manage anything else:

- A **storage account** in Azure with a `tfstate` container for all platform state
  files, plus one container per domain per environment (`tfstate-dev-claims`, etc.)
  for domain state files. Only the domain's deploy SP has access to its own container.
- The **platform Terraform SP** (`sp-piq-terraform`) with OIDC trust for the
  platform repository.
- **Role assignments** giving that SP Contributor and RBAC Administrator on the
  subscription.

Runs locally as the Global Administrator because the SP does not exist yet.

---

### Stack 10-foundation — Azure infrastructure

Creates the Azure resources that all subsequent stacks and all domain pipelines
depend on.

| Resource | Purpose |
|---|---|
| Resource groups (`rg-piq-dev`, `rg-piq-prd`) | Container for all Azure resources per environment |
| Virtual network + subnets | Private network for Databricks cluster nodes. Two subnets per workspace: host (nodes) and container (internal traffic). No public IPs. |
| Databricks workspaces (`dbw-piq-dev`, `dbw-piq-prd`) | Premium tier — required for Unity Catalog, serverless compute and ABAC |
| Storage account per environment | ADLS Gen2 data lake. Unity Catalog stores all table data here, one container per catalog |
| Per-domain state containers | `tfstate-{env}-{domain}` — isolated state storage for each domain's Terraform. Only that domain's deploy SP can write to it |
| Access Connector | Managed identity used by Unity Catalog to read/write storage. No passwords |
| Key Vault | Reserved for secrets that cannot use OIDC |

VNet injection puts cluster nodes inside your own network rather than Microsoft's,
giving you control over firewall rules and private connectivity.

---

### Stack 20-identity — Entra groups, service principals and administrative units

Creates all identity objects in Microsoft Entra ID. Databricks reads from Entra
automatically via Automatic Identity Management — no SCIM configuration needed.

| Resource | Purpose |
|---|---|
| Domain role groups (`piq-dev-claims-producer`, etc.) | One per environment × domain × role. Access control principals for catalogs, schemas and warehouses |
| Writer groups | One per environment × domain. Members are exempt from column masks and are the only identities that write domain data in prd |
| Vault groups | Engineer and writer roles for the shared raw vault |
| Consumer groups | Prd-only groups owned by the consumer lead |
| SAR groups | Sensitive Access Role groups that unlock column masks for their members |
| Platform and persona groups | Cross-domain groups: workspace admins, governance, monitoring, personas |
| Administrative units | One per domain per environment. The domain's deploy SP is scoped to its own unit |
| Per-domain deploy SPs | One per environment × domain. OIDC trust scoped to `repo:<org>/<domain-repo>:environment:<env>`. No passwords. |
| Vault loader SP | Writes to the shared raw vault. OIDC trust scoped to the vault repository |

After this stack runs, all groups appear in the Databricks account console labelled
"In Microsoft Entra ID" — they are read from Entra, not managed by Databricks.

---

### Stack 30-account — Databricks account configuration

Operates at the Databricks account level, which sits above all workspaces.

| Resource | Purpose |
|---|---|
| AIM resolution | Pulls each Entra group and SP into the Databricks account so they can be referenced in grants. Also runs on a schedule to pick up domain-created product groups (Pattern 3) |
| Workspace assignments | Assigns groups and SPs to dev or prd workspace with USER or ADMIN permission |
| Serverless usage policies | Tags every serverless DBU with `piq_env` and `piq_domain` for cost attribution |
| Budgets | Alert-only cost budgets per environment, domain, vault and consumer. Email alerts at 50/80/100% of monthly limit |
| Egress network policies | Controls which external URLs serverless compute can reach. Starts in DRY_RUN; switch to ENFORCED after reviewing denial logs |

---

### Stack 40-unity-catalog — catalogs, grants, tags and delegation

Unity Catalog is the governance layer across all workspaces: a single place to
manage all data assets with fine-grained access control. Everything lives at
`catalog.schema.table`.

In the federated model, the platform creates and owns catalogs and catalog-level
grants. Schemas inside domain catalogs are owned and managed by the domain.

| Resource | Purpose |
|---|---|
| Catalogs | Domain catalogs (`dev_claims`, `prd_claims`), vault, consumer prep, anonymized (`prd_claims_anon`), platform and sandbox |
| Storage bindings | Links each catalog to its ADLS Gen2 container |
| Catalog-level grants | Which groups have USE CATALOG on each catalog. Product isolation: product groups get USE CATALOG without BROWSE |
| Catalog-users groups | One per domain catalog. The domain adds its product groups here; the platform grants USE CATALOG to this group |
| Delegated rights | The domain's deploy SP gets USE CATALOG, BROWSE, CREATE SCHEMA and MANAGE on its own catalog. It owns the schemas it creates |
| Admin schema | The one schema the platform creates inside each domain catalog |
| Vault, platform, sandbox schemas | Created and managed by the platform |
| Governed tags | Tag taxonomy enforced by Databricks. Only authorised groups can apply tags. Tags trigger column masking |
| ABAC policy definitions | Which mask function applies to which tag value on which catalog. Activated by stack 60 |

The environment never appears in schema names. A domain's dbt model runs in dev
and prd unchanged.

---

### Stack 50-workspace — warehouses and compute policies

Creates objects inside each workspace.

| Resource | Purpose |
|---|---|
| SQL Warehouses | Serverless compute for SQL. One per domain, one for the vault, one per consumer (prd only), one shared. Each scales to zero when idle |
| Compute policies | Restrict cluster size, require auto-termination and cost tags |
| IP access lists | Optional: restrict workspace login to specific CIDRs |
| System table access | Enables Databricks system tables (audit, query history, cost) for stack 70 |

Each domain has its own warehouse so its compute cost is isolated and attributable.
The shared warehouse is used by governance and platform monitoring.

---

### Stack 55-ai-platform — AI infrastructure

Optional per-domain features controlled by flags in each domain's config file.

| Resource | Purpose |
|---|---|
| App Spaces | Databricks Apps hosting — for domains with `app_space: true` |
| Vector search endpoints | For domains using semantic search and embeddings |
| Lakebase | Managed Postgres-compatible database — for domains with `lakebase: true` |

---

### Stack 60-governance — column masking

Applies ABAC column-mask policies across all domain, vault and consumer catalogs.

| Resource | Purpose |
|---|---|
| Masking SQL functions | `mask_ssn()`, `mask_dob()`, `mask_email()`, etc., stored in `{env}_platform.governance`. Return a redacted value unless the caller is exempt |
| ABAC column mask policies | Attaches each function to each catalog, triggered by governed tag values |

How it works end to end:
1. A domain engineer tags a column: `ALTER TABLE ... SET TAGS ('pii' = 'ssn')`
2. Stack 60 has a policy on that catalog: mask any column where `has_tag_value('pii', 'ssn')` using `mask_ssn()`, except the SAR group and the writer SP
3. A producer analyst queries the column — sees `***-**-1234`
4. The analyst is granted the `claimant_pii` SAR via a PR to `config/sars.yaml` approved by governance — now sees the real value

Masking is automatic and catalog-wide. No per-table rules. Schemas created by the
domain after stack 60 runs are covered immediately because the policy is on the
catalog, not individual schemas.

---

### Stack 70-observability — monitoring views

Creates SQL views in `prd_platform` over Databricks system tables. System tables
record every query, job run, permission change and cost event across the account.

| View | What it shows |
|---|---|
| `monitoring.cost_daily_by_env_domain` | Daily spend by environment and domain |
| `monitoring.cost_untagged_usage` | Compute without `piq_domain` tags — bypassed usage policies |
| `audit.denied_requests` | Permission-denied events: who tried what and was refused |
| `audit.permission_changes` | Every grant and revoke |
| `governance.pii_columns` | All columns currently tagged with PII tags |
| `governance.lineage_recent` | Data lineage: which tables read from which |
| `governance.products` | Published product catalog across all domains |
| `observability.query_activity_daily` | Query volume and latency by warehouse |
| `observability.job_run_outcomes` | Job success and failure rates |

Views are created by running SQL files through the Databricks Statement Execution
API. Terraform re-runs a file whenever its contents change.
