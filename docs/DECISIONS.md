# Architecture decision records

Short records of the choices that shape this repo. Status of all: **Accepted**.

### ADR-001 Azure Databricks over AWS/GCP
Identity and the access portal already run on Microsoft Entra ID. Azure Databricks
syncs Entra users, groups (including nested) and service principals automatically,
removing SCIM. An individual can create the account by creating a workspace, and
Premium is the only tier for new workspaces, so all enterprise features are present.
*Consequence:* the design is Azure-specific at the edges (access connectors,
`azurerm`, `azuread`); Unity Catalog and the access model are cloud-neutral.

### ADR-002 Workspace per environment, catalog per domain
Two workspaces (dev, prd); domains are catalogs `{env}_{domain}`. One platform
team serves all domains, so per-domain workspaces would multiply admin work.
Isolation comes from workspace-catalog binding. *Revisit* if a domain gets its own
team, budget and admins.

### ADR-003 Privilege bundles instead of access-role objects
Unity Catalog grants inherit down the hierarchy and go straight to groups. The
Snowflake `_R/_RW/_RWC` layer is kept as named bundles in YAML, not as groups.
*Consequence:* fewer objects; the matrix stays readable.

### ADR-004 Entra is the only identity source
Groups and memberships are managed in Entra by Terraform (`azuread`). Databricks
shows them as External and read-only. *Consequence:* app service principals (created
by Databricks per app) cannot join these groups; they get direct grants via bundles.

### ADR-005 prd writes by service principals only
Prd producer groups contain only the domain deployers (`sp-piq-prd-{domain}-deploy`, ADR-020). Enforced twice: the naming
module precondition and `validate_config.py`. *Consequence:* engineers debug prd
with read access and fix forward through CI.

### ADR-006 OIDC federation, no secrets, no PATs
GitHub Actions authenticates to Entra with OIDC; Terraform and the Databricks CLI
use that Azure CLI session. Personal access tokens are disabled.

### ADR-007 Terraform desired state replaces versioned migrations
Platform objects are declared, not migrated. Table DDL lives with pipelines in
domain repos (Asset Bundles). SQL-only objects (masking functions, views) are
re-run idempotently when their file hash changes.

### ADR-008 Layered stacks with separate state
Eight stacks ordered by blast radius and dependency. A bad grant change cannot
touch networking; identity changes never re-plan storage.

### ADR-009 ABAC tag-driven masking, one policy per catalog x PII type
Masks attach at catalog level and match columns by `pii` tag value. Producers,
admins and DB admins of the domain are exempt. *Consequence:* tagging is a
security boundary; tag assignment is restricted and CODEOWNERS-reviewed.

### ADR-010 Shared serverless warehouses, attribution by tags
Two warehouses per env instead of per-domain warehouses. Serverless usage policies
tag spend by env x domain. *Consequence:* no hard per-domain spend ceiling; budgets
alert, compute settings cap.

### ADR-011 Masking functions per environment
Functions live in `{env}_platform.governance`, not a shared catalog, because an
ISOLATED catalog is not reachable from the other workspace and a mask function must
be resolvable wherever the masked table is queried.

### ADR-012 On-behalf-of-user by default for apps and agents
User-facing apps query as the signed-in user so ABAC applies to the person. App
service principals hold only app-owned resources.

---

## Product architecture (supersedes parts of ADR-002, 003, 009, 010)

### ADR-013 Shared enterprise raw vault
One `{env}_vault` catalog, written only by `sp-piq-{env}-vault-loader`.
Data Vault integrates on business keys shared across domains; per-domain
vaults would duplicate hubs or give them two owners. Stewardship is recorded
with `piq_steward_domain` and `piq_source_system` tags. Business vaults are
owned by domains. *Trade-off:* the vault team can become a bottleneck;
metadata-driven loaders keep adding a source a configuration review.

### ADR-014 No Vault DAPs
With a shared vault, domains read it through grants. A published interface over
raw vault entities would duplicate that contract.

### ADR-015 One catalog per domain, products as schemas
Private and product schemas share `{env}_{domain}`. Promotion is a config entry
and a model target change; no data moves. The private/published boundary is
enforced by grants: product groups get `USE_CATALOG` without `BROWSE` and read
only their product schema. *Revisit* with a separate published catalog if a
grant mistake would be unacceptable. Supersedes the medallion layout of ADR-002.

### ADR-016 One workspace per environment for producers and consumers
Isolation from grants, warehouse ACLs and cost tags is sufficient. A consumer
workspace can be added later as configuration plus read-only bindings, if
consumer teams need to administer their own workspace.

### ADR-017 Environment only where names span environments
Catalogs (one metastore serves both environments), Entra groups, service
principals and usage policies carry the environment, as a prefix. Schemas and
workspace objects do not. Code never contains an environment.

### ADR-018 SARs are the only mask exceptions
Supersedes the producer/admin exemption of ADR-009. Masks exempt SAR groups and
the identities that write the data. Producers build with masked values.

### ADR-019 Dedicated warehouses per domain, vault and consumer
Supersedes ADR-010. SQL warehouse usage is not covered by usage policies, so
dedicated, tagged warehouses are the only exact SQL attribution. Serverless
warehouses make the idle cost of several small warehouses negligible.

### ADR-020 Per-domain deployers and product files per domain
Each domain deploys with its own service principal, trusted only from its own
repo's GitHub environment. Product definitions live in one file per domain so
CODEOWNERS can route consumer approvals to the producing domain.

### ADR-021 Anonymized production data through read-only catalogs
`prd_{domain}_anon`, written by an anonymization job in prd and bound
read-only to dev, is the only path from prd to dev.
