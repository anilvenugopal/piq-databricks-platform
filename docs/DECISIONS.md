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

### ADR-005 prod writes by service principals only
Groups of service-principal-only roles (`producer`, plus any role a domain flags
`service_principal_only`) in the **prod-tier** environment contain only the domain
deployers (`sp-piq-prd-{domain}-deploy`, ADR-020). Enforced twice: the naming
module precondition and `validate_config.py`. *Consequence:* engineers debug prd
with read access and fix forward through CI. The rule follows the environment's
tier, not its name (ADR-023).

### ADR-006 OIDC federation, no secrets, no PATs
GitHub Actions authenticates to Entra with OIDC; Terraform and the Databricks CLI
use that Azure CLI session. Personal access tokens are disabled.

### ADR-007 Terraform desired state replaces versioned migrations
Platform objects are declared, not migrated. Table DDL lives with pipelines in
domain repos (Asset Bundles). SQL-only objects (masking functions, views) are
re-run idempotently when their file hash changes.

### ADR-008 Layered stacks with separate state
Nine stacks ordered by blast radius and dependency. A bad grant change cannot
touch networking; identity changes never re-plan storage. ADR-022 splits each
stack's state further, by scope.

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
workspace objects do not. Domain and pipeline code never contains an environment.
Platform code tests the environment's tier instead (ADR-023).

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

---

## Environments, scopes and entitlements (CR-002)

None of the decisions below has been applied to real cloud yet. They are checked by
tests that need no cloud access (see ARCHITECTURE.md section 18).

### ADR-022 Scopes and one state per scope
Every group, catalog, schema, grant, warehouse, policy and service principal belongs to
exactly one **scope**: `shared`, `env`, `access` or `domain:<name>`. Each scope in each
environment has its own Terraform state (`<stack>/<env>/domain-claims.tfstate`, and so
on). The naming module is always computed in full; its `environment` and `scope`
inputs only filter the outputs, so scopes refer to each other's objects by computed
name, not by reading remote state.
*Why:* with one state per stack, deploying a change for claims also compared and
could change every other domain, and dev and prd moved together. Separate states
make "deploy claims to prd" touch only claims in prd.
*Consequence:* a deploy is a target (stack, environment, scope). A new domain takes
more than one run (ARCHITECTURE.md section 14). A **scope check** reads the saved
plan and refuses a change to another scope's resources. It is a second lock behind the
state split, not the first one.
*Rejected:* `terraform apply -target` (fragile, easy to forget a resource), and a
single state with a scope check only (it would block claims whenever another domain
had an unapplied merged change).

### ADR-023 Environment tiers instead of environment names
Each environment declares `tier: nonprod|prod`, `promotes_from` and `allow_hotfix`.
Exactly one environment is prod. Rules key off the tier: who may write, where consumer
domains, anonymized data and experiments live, where sandboxes are allowed, which
environment runs observability. *Why:* the repo had "dev" and "prd" written into code
and config rules, so adding qa, uat or a second dev would have meant code changes.
*Consequence:* a new environment is configuration (ARCHITECTURE.md section 13). Bundles
in `access_matrix.yaml` may differ by tier, so dev can have more access than prd from
the same table.

### ADR-024 Releases are tags; environments form a promotion graph
`main` is the only long-lived branch. `scripts/release.py` cuts immutable tags
`rel-YYYY.MM.DD.N`. An environment with `promotes_from` accepts only a release tag that
has a successful deploy record in **every** listed environment, for the same stack and
scope; `HEAD` must be that tag with a clean tree. `promotes_from` may list several
environments, so environments form a graph, not a line. A hotfix skips the gate only
where `allow_hotfix` is true, with a named approver, and must be replayed through the
skipped environments afterwards.
*Why:* several dev deploys can happen before one prod release; prod can take any
proven tag, not only the newest; rollback is redeploying an older tag.
*Consequence:* an empty plan still records the release as deployed, so a release that
does not touch a domain remains promotable for it. Deploy records live in the state
storage account.

### ADR-025 Entitlements are separate from infrastructure
Which people are in which group, and which access requests were approved (persona
members, product consumers, SAR members, sandbox and experiment members, domain
admins), live in `config/entitlements/<env>/` and are applied only by stack
`25-access`. The stacks that create groups never add people.
*Why:* in most organisations an identity-governance tool (SailPoint, Saviynt, PingID)
owns these decisions. This platform has none yet, so the folder is its stand-in.
*Consequence:* to hand the job to a tool, delete the folder and stack 25. The group
**names** produced by the naming module are the contract between the two. Grants of
privileges on data (what a group may do) stay here, because they must match the objects
this repo creates. Consumer group membership stays with the consumer lead in Entra.

### ADR-026 Standard plus per-domain additions
Every domain gets the standard schemas, roles and personas. A domain may add or drop
schemas, add roles and add its own personas through two files with different approvers:
`domain_shape/<domain>.yaml` (the domain team declares) and
`domain_access/<domain>.yaml` (platform and governance decide what the roles may do).
Limits: no bundle above `override_ceiling` (`RWC`), the `admin` schema is untouchable,
names may not collide with standard or reserved names, and a domain persona may only
reference its own domain's roles.
*Why:* domains differ, but the common structure keeps the platform operable and
reviewable. *Consequence:* "all roles" became "this domain's roles" throughout the
naming module, and the wildcard `dev:*:analyst` means every domain that defines the role.

### ADR-027 One Terraform identity per environment
`bootstrap/` creates `rg-piq-<env>` per environment and `sp-piq-terraform-<env>`, whose
Azure rights are limited to that resource group, plus the shared `sp-piq-terraform`. Each
trusts only its own GitHub environments over OIDC (`<env>`, `<env>-plan`; `shared`,
`shared-plan`).
*Why:* a dev pipeline should not be able to change prd's Azure resources.
*Limits, stated plainly:* Entra Graph permissions and Databricks account admin cannot be
limited per environment, and the state storage account is shared, so the separation is
partial. Entra administrative units (CR-001) and per-environment state containers would
close those gaps.

### ADR-028 No environment branches
There are no `dev` or `prd` branches. The same commit has to reach every environment, and
a branch per environment drifts and invites cherry-picks. Promotion moves a tag through
environments (ADR-024). *Consequence:* a shared-rule change merged to `main` reaches each
domain on its next deploy; roll it out to every domain deliberately, or deploy from an
earlier tag. Urgent single changes use a hotfix.

### ADR-029 Deploys are started by hand, as plan then approve
`deploy.yml` runs only when someone dispatches it for one target. Job 1 plans, runs the
scope check and saves the plan; job 2 waits for the GitHub environment's reviewers (required
on the prod environment), then applies **that saved plan**. `apply.py --yes` is refused
without `--plan`, so a pipeline never applies a plan nobody read. Nightly, `drift.yml` plans
every target and never applies. *Why:* a merge must not change an environment by itself,
and the approver must see exactly what will be applied. *Rejected:* auto-apply on merge to
dev (a bad merge would change dev immediately); revisit once the scopes are proven.
