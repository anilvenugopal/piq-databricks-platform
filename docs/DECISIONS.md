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
Prd producer groups contain only `sp-piq-prd-deploy`. Enforced twice: the naming
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
