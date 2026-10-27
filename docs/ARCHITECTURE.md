# Architecture

What the platform is and why each choice was made. For the steps to build it,
see [RUNBOOK.md](RUNBOOK.md); for day-2 procedures, [OPERATIONS.md](OPERATIONS.md).

## 1. Topology

```
Microsoft Entra ID ──(automatic identity management)──┐
  users, groups, service principals                    ▼
GitHub Actions ──(OIDC)──> sp-piq-terraform[-<env>] ──> Databricks account
                                                 ├─ Unity Catalog metastore (one per region)
                                                 ├─ dbw-piq-dev ── dev_* catalogs ─────────── ADLS dev
                                                 └─ dbw-piq-prd ── prd_* catalogs ─────────── ADLS prd
                                                       prd_claims_anon ──read-only──> dbw-piq-dev
```

| Plane | Lives in | Holds |
|---|---|---|
| Control plane | Databricks' Azure subscription | UI, APIs, scheduler, Unity Catalog metadata |
| Classic compute plane | Your VNet | Cluster VMs, only when classic compute is used |
| Serverless compute plane | Databricks-managed, same region | Warehouses, serverless jobs and pipelines, apps, serving |
| Data | Your storage accounts | Every managed table, volume and file |

The diagram shows two environments, `dev` and `prd`, because that is what
`config/platform.yaml` lists today. The environment list is configuration, not
code: see section 13 for how another one (qa, uat, dev2) is added.

One workspace per environment. Producers and consumers work in the same
workspace; isolation comes from grants, warehouse permissions and cost tags,
not from separate workspaces. A consumer workspace can be added later as a
configuration change plus read-only bindings.

## 2. Domains and products

| Kind | Examples | Catalog | Publishes | Reads |
|---|---|---|---|---|
| Shared raw vault | vault | `{env}_vault` | Nothing (internal) | Source systems |
| Producer domain | claims, policy_financial | `{env}_{domain}` | Base products | The vault |
| Derived producer | profitability | `{env}_{domain}` | Products built from products | Other domains' products, the vault |
| Consumer domain | exec_reporting | optional `{prod env}_{consumer}` | Nothing | Products it is approved for |

A **product** is one schema `product_{name}` in its domain's catalog (tables,
views, functions, models or agents; apps run in the domain's App Space) and one
Entra group `piq-{env}-product-{name}`. Publishing is an entry in
`config/products/<domain>.yaml`. Approving a consumer is an **entitlement**, not
part of the product file: it is a line in
`config/entitlements/<env>/product_access.yaml` (see section 15), and stack
`25-access` nests the consumer's groups into the product group. Because the file
is per environment, a consumer can be approved in dev and not yet in prod.
Consumer domains exist only in the prod environment.

Derived products read **products**, never another domain's private schemas, so
a domain can change anything behind its contract. A product's approved
consumers (its entry in `product_access.yaml`) are its impact list; Unity
Catalog lineage shows the chain.

## 3. Catalogs and schemas

| Catalog | Schemas |
|---|---|
| `{env}_vault` | `landing` (volumes), `stage_{source}`, `raw_vault`, `business_vault_core`, `admin` |
| `{env}_{domain}` | private: `admin`, `business_vault`, `info_mart`, `reporting`, `sandbox`, `ai`, `event_log`; products: `product_{name}` |
| `{prod env}_{consumer}` | `staging`, `prep`, `reporting` |
| `{prod env}_{domain}_anon` | `data` |
| `{env}_platform` | `governance` (mask functions), `audit`, `monitoring`, `observability` |
| `{env}_sandbox` | `u_{user}` (nonprod environments), `exp_{name}` (prod environment) |

The private schemas listed for `{env}_{domain}` are the **standard** set (the
`schemas:` list in `config/domains.yaml`). A domain can add schemas or drop a
standard one: see section 16. Examples in this document use `dev` and `prd`;
read `{prod env}` as `prd` today.

Bindings: every catalog is bound read-write to its environment's workspace.
`{prod env}_{domain}_anon` is also bound read-only to every nonprod environment
(`dev` today). Nothing else crosses.

Storage chain per catalog: access connector (managed identity) → storage
credential → external location → managed location. Users hold no storage
permissions; Unity Catalog vends short-lived, path-scoped credentials.

## 4. Data Vault flow

| Layer | Where | Owner | Writer |
|---|---|---|---|
| Landing | `{env}_vault.landing` | Vault team | `sp-piq-{env}-vault-loader` |
| Staging | `{env}_vault.stage_{source}` | Vault team | vault loader |
| Raw vault | `{env}_vault.raw_vault` | Vault team | vault loader |
| Shared business vault | `{env}_vault.business_vault_core` | Vault team | vault loader |
| Business vault | `{env}_{domain}.business_vault` | Domain | domain deployer |
| Information marts | `{env}_{domain}.info_mart` | Domain | domain deployer |
| Products | `{env}_{domain}.product_{name}` | Domain | domain deployer |

Vault tables carry `piq_steward_domain` and `piq_source_system` tags. Promotion
moves no data: a product's dbt models change their target schema from
`info_mart` to `product_{name}`.

## 5. Identity

All identities live in Entra ID (stack 20); Databricks sees them through
automatic identity management and stack 30 resolves them into the account.

| Group | Pattern | Purpose |
|---|---|---|
| Local roles | `piq-{env}-{domain}-{producer, analyst, ai, dbadmin}` plus any role the domain adds | Domain team access |
| Writer | `piq-{env}-{domain}-writer` | The domain deployer; exempt from masks |
| Vault | `piq-{env}-vault-{engineer, writer}` | Vault team; writer holds the loader |
| Product | `piq-{env}-product-{name}` | Readers of one product |
| Consumer | `piq-{prod env}-{consumer}-{role}` | Consumer domain; owned and populated by its lead |
| SAR | `piq-{env}-sar-{policy}` | Sensitive access; members approved by governance |
| Platform | `piq-{name}`; `piq-{env}-workspace-admins` is generated for every environment | mesh-admins, metastore-admins, mesh-governance, monitoring, sandbox-users, prd-experimenters |
| Persona | `piq-{env}-persona-{name}` | Global job personas, one group per environment, nested into that environment's groups only |
| Domain persona | `piq-{env}-persona-{domain}-{name}` | A persona that exists in one domain only (section 16) |

A persona has the same shape everywhere but its own `access` list in each
environment (`config/personas.yaml`). A data-engineer is nested into the
domain **producer** groups in dev and into the **analyst** (read-only) groups in
prd. Who holds a persona is an entitlement (section 15).

Service principals: `sp-piq-{env}-{domain}-deploy` per domain (member of its
producer and writer groups), `sp-piq-{env}-vault-loader`, plus extras in
`service_principals.yaml`. All authenticate with GitHub OIDC, scoped to
`repo:<org>/<repo>:environment:<env>`. In the prod environment, groups of
service-principal-only roles (`producer`, plus any extra role flagged
`service_principal_only`) contain only deployers: humans read prod and change
it through CI. The Terraform identities themselves are described in section 17.

## 6. Access model

Privilege bundles (`config/access_matrix.yaml`):

| Bundle | Privileges |
|---|---|
| R | `USE_SCHEMA`, `SELECT`, `EXECUTE`, `READ_VOLUME` |
| RW | R + `MODIFY`, `WRITE_VOLUME` |
| RWC | RW + `CREATE_TABLE`, `CREATE_MATERIALIZED_VIEW`, `CREATE_FUNCTION`, `CREATE_VOLUME`, `CREATE_MODEL` |
| O | `ALL_PRIVILEGES`, `MANAGE`: the grantable equivalent of ownership |

A bundle in the matrix can be a plain value (`analyst: RW`) or differ by
**tier** (`analyst: { nonprod: RW, prod: R }`), so the same table gives dev more
access than prd without naming either environment.

Domain catalog: local roles get `USE_CATALOG` + `BROWSE`; dbadmin gets O;
product groups get `USE_CATALOG` only, so consumers never see private schema
names. Schema grants follow the matrix; each product schema adds R for its own
product group; `event_log` adds R for all the domain's product groups. The real
owner of every catalog is the Terraform service principal, and grants are
authoritative: anything granted by hand is removed on the next apply.

Workspace objects are a second permission plane: warehouse, policy and endpoint
ACLs come from `workspace_objects.yaml` and the naming module.

## 7. Sensitive data

Masks are ABAC column-mask policies on every domain, vault and consumer prep
catalog, one per mask in `governed_tags.yaml`, matching columns by tag
(`pii = ssn`, `sensitive_metric = financial`, ...). Exceptions are only:

- SAR groups that unlock that mask, in every catalog. `config/sars.yaml` defines
  each SAR and the masks it unlocks; who is a member is an entitlement
  (`config/entitlements/<env>/sars.yaml`);
- the catalog's data writers (domain writer group, vault writer group).

Producers, analysts, product and consumer groups all see masked values unless
they hold the SAR. Derived products must carry sensitive tags forward on any
column they republish. Masks do not apply inside files: raw documents stay in
the vault's `landing` volume.

## 8. Compute and cost

| Warehouse | Users | Tags |
|---|---|---|
| `piq-{domain}-transform` (per env) | that domain's producer, analyst, ai | `piq_domain = {domain}` |
| `piq-vault-load` | vault writer, engineers | `piq_domain = vault` |
| `piq-{consumer}-bi` (prod environment) | that consumer's groups | `piq_domain = {consumer}` |
| `piq-shared` | sandbox users, governance, monitoring | `piq_domain = shared` |

Producer warehouses are never granted to consumers. Serverless usage policies
tag all other serverless usage by env and owner. Budgets alert at 75/90/100%;
they never stop compute (auto-stop and compute policies cap it).

## 9. Naming

The environment appears only in names whose scope spans environments:

| Object | Environment in name | Example |
|---|---|---|
| Workspace | Yes | `dbw-piq-prd` |
| Catalog | Yes, prefix | `prd_claims` |
| Group, service principal | Yes | `piq-prd-claims-producer`, `piq-prd-persona-data-engineer` |
| Usage policy, budget | Yes | `piq-prd-claims` |
| Schema, table, function, volume | No | `prd_claims.product_loss.loss_triangle` |
| Warehouse, job, app, App Space | No | `piq-claims-transform` |

This rule applies to the platform code too: the naming module and the stacks
never test for the name "dev" or "prd". They test the environment's **tier**
(section 13). Domain and pipeline code never contains an environment: bundles pass `env`, dbt tasks set
`catalog = {env}_{domain}`, SQL uses `IDENTIFIER(:env || '_claims...')`,
notebooks read `env` from a job parameter.

## 10. Network and security

VNet injection with no public IPs; optional NAT for classic egress; IP access
lists (off by default, incompatible with GitHub-hosted runners); serverless
egress policies (prod environment restricted, dry run first); PATs disabled; storage shared
keys disabled. Private Link and customer-managed keys are later hardening steps.

## 11. AI and apps

Each domain has an `ai` schema and an App Space; agents and apps that are
products keep their tables, functions and registered models in their product
schema. Apps and agents query data on behalf of the caller (template
`templates/obo-app`), so masks and grants apply to the person. Vector Search
endpoints are per environment; index access is data access. AI spend has its
own budget; outbound calls are limited by serverless egress policies.

## 12. Observability

Views in `{prod env}_platform` over system tables (stack 70 runs only in the prod environment): cost by env and domain, untagged
usage, query activity, job outcomes, denied requests, permission changes, PII
columns, lineage, and the product catalog (`governance.products`).

---

The sections below describe how the platform is **deployed**: environments, scopes,
entitlements and identities. Nothing described in sections 13 to 17 has been
applied to real cloud yet. It is checked by tests that need no cloud access
(section 18).

## 13. Environments, tiers and releases

The list of environments lives in `config/platform.yaml`. Each one says what **tier** it
is and where releases may come from:

```yaml
environments:
  dev: { tier: nonprod, promotes_from: [],    allow_hotfix: false, ... }
  prd: { tier: prod,    promotes_from: [dev], allow_hotfix: true,  ... }
```

| Field | Meaning |
|---|---|
| `tier` | `nonprod` or `prod`. Exactly one environment must be `prod`. |
| `promotes_from` | Environments a release must already have been deployed to successfully. Empty means any commit may be deployed here. |
| `allow_hotfix` | `true` lets a hotfix skip `promotes_from`, with a named approver. |

**Rules depend on the tier, never on the name.** The naming module and the validator use
the tier everywhere:

| Rule | Tier it applies to |
|---|---|
| Humans cannot join groups of service-principal-only roles (`producer`, plus any role a domain flags) | prod |
| Consumer domains, their warehouses and prep catalogs live here | prod |
| Anonymized catalogs (`{env}_{domain}_anon`) are written here | prod |
| Anonymized prod data is readable (read-only binding, `USE_CATALOG` + `BROWSE`) from every environment of this tier | nonprod |
| Personal sandboxes (`u_{user}`) are allowed | nonprod |
| Experiments (`exp_{name}`) are allowed | prod |
| Stack 70 (observability views) runs | prod |
| Vault engineers write (`vault.overrides` in `access_matrix.yaml`) | nonprod |

### Adding an environment

`promotes_from` can name any number of environments, so environments form a graph, not a
single line:

```
dev1, dev2 ──> qa ──> uat ──> prd
  qa:  promotes_from: [dev1, dev2]    (needs the release in BOTH)
  prd: promotes_from: [uat]
```

To add `qa`: add its entry (with its `network` block) to `platform.yaml`, add `qa` to
`access:` of each persona in `config/personas.yaml`, add `config/entitlements/qa/`, and add
its names to the platform groups' `workspaces:` where needed (`sandbox-users` for a nonprod
environment), and optionally add its `environment_monthly_usd` budget in `config/cost.yaml` (an
environment with no entry gets no environment budget). Run bootstrap again so it creates `rg-piq-qa` and `sp-piq-terraform-qa`. No code
changes. `<env>-workspace-admins` is generated automatically. Only one environment may be `prod`.

### Releases and promotion

`main` is the only long-lived branch. There are no `dev` or `prd` branches: the same code
has to reach every environment, and a branch per environment drifts.

```
merge to main ──> deploy to dev (any commit, as often as you like)
                       │  scripts/release.py  cuts  rel-2026.10.23.1
                       ▼
                 deploy that TAG to prd  (gate: must have succeeded in dev first)
```

- A **release tag** is an immutable git tag `rel-YYYY.MM.DD.N` made by `scripts/release.py`.
  An environment with `promotes_from` only accepts a release tag.
- The **promotion gate** (`util/deploys.py`, run by `scripts/apply.py`) refuses a release
  unless every environment in `promotes_from` has a deploy record with outcome `PASS` for the
  same release, the same stack and the same scope. Deploying claims to dev says nothing about
  profitability.
- The code that runs must be the code of the tag: `HEAD` has to be the tag's commit and the
  working tree clean.
- Every apply writes a **deploy record** (release, commit, who, outcome) to the `deployments`
  container of the state storage account. An empty plan still records the release as
  deployed, so a release that does not touch a domain can still be promoted for it.
  `scripts/status.py` shows the latest release per target.
- **Hotfix:** `scripts/apply.py ... --hotfix --approver NAME`. It works only where
  `allow_hotfix` is true. Afterwards replay the release through the environments it skipped
  and merge the fix to `main`.
- A change to shared rules (for example `access_matrix.yaml`) reaches each domain on that
  domain's next deploy, together with whatever else it deploys. Roll such a change out to
  every domain deliberately, dev first, or deploy from an earlier tag.

## 14. Scopes and state

**State** is Terraform's record of what it built. A run compares your config with that
record to decide what to change. One shared record for everything means a run for claims also
looks at, and may change, everything else. So the platform is split into **scopes**, and each
scope has its own state.

| Scope | Owns | Example |
|---|---|---|
| `shared` | Things that span all environments; no environment | Governed tag definitions, `piq-mesh-governance`, `piq-metastore-admins`, the AI Gateway budget |
| `env` | One environment's infrastructure | `dev` network, workspace and storage; the vault, platform and sandbox catalogs; `piq-dev-workspace-admins`; global personas |
| `access` | People and approvals in one environment (stack 25) | Who holds which persona; which consumer may read which product |
| `domain:<name>` | One domain in one environment | `prd_claims` and its schemas and grants, claims role groups, claims warehouse, claims masks |

Every item the naming module produces carries its scope and an `sid`: `shared`,
`<env>/env`, `<env>/access` or `<env>/domain:<name>`. Each scope has its own state file:

| Scope | State key (in the state container) |
|---|---|
| `shared` | `<stack>/shared.tfstate` |
| `env` | `<stack>/<env>/env.tfstate` |
| `access` | `<stack>/<env>/access.tfstate` |
| `domain:<name>` | `<stack>/<env>/domain-<name>.tfstate` |

Which stack supports which scope (`stacks/<stack>/stack.yaml`):

| Stack | Scopes |
|---|---|
| 10-foundation | env |
| 20-identity | shared, env, domain |
| 25-access | access |
| 30-account | shared, env, domain |
| 40-unity-catalog | shared, env, domain |
| 50-workspace | env, domain |
| 55-ai-platform | env, domain |
| 60-governance | env, domain |
| 70-observability | env (prod environment only) |

A **deployment target** is a stack plus a scope plus (except `shared`) an environment, for
example `40-unity-catalog` / `prd` / `domain:claims`. `scripts/tf.sh`, `plan.py`, `apply.py` and
`check.py` all take `--scope` and `--env`.

### How the scopes fit together

- **The naming module is always computed in full.** `modules/naming` takes `environment` and
  `scope` inputs, but they only **filter the outputs**. Inside, every name, group and grant is
  still worked out, so the `env` run can write the vault-catalog grant for
  `piq-prd-claims-producer` without reading claims' state, and the claims run can write
  the grant "piq-prd-claims-analyst may read `prd_claims.reporting`" on its own.
- **Names link scopes, not remote state.** One scope refers to another scope's object by its
  computed name (`prd_lake_credential`, `piq-prd-product-loss`). The stacks still read
  remote state for a few facts: the environment's workspaces and storage (stack 10, `env`),
  the usage policies of the same scope (stack 30, read by 55), and warehouse ids (stack 50,
  read by 60 and 70).
- **A group-in-group edge belongs to its parent's scope**, except that an edge into a
  **shared** group belongs to the **child's** scope. The parent is the group that grants the
  access. If the other end belongs to another scope, the stack finds it by display name, so
  that scope must have been applied first. Example: the persona `piq-prd-persona-data-engineer`
  (`prd/env`) is nested into `piq-prd-claims-analyst` (`prd/domain:claims`), so the edge is created
  by the claims run, which looks the persona up by name. Its edge into the shared group
  `piq-metastore-admins` (for `platform-admin`) is created by the `prd/env` run, so `shared` never
  waits for an environment.
- **Shared things are assigned by each environment.** A shared group such as
  `piq-mesh-governance` is assigned to a workspace by that environment's `env` run, so `shared`
  never depends on an environment.

### The scope check

Before anything is applied, `scripts/plan.py` and `scripts/apply.py` read the saved plan
(as JSON) and look at every resource it would create, change or delete. Each resource made from a
`for_each` has an instance key such as `domain:prd:claims/product_loss`. The check looks that key up in the naming output and
refuses the plan if the key belongs to another environment or scope (`util/scope_check.py`, exit
code 4). It is a second lock behind the separate states: with one state per target a plan cannot
contain other targets' resources anyway, so the check catches mistakes in how a stack was split.
A key the check cannot attribute is reported as a note, not a failure.

### Deploy order

For each environment, in this order (a `domain` step is repeated for every domain):

| Step | Targets |
|---|---|
| 1 | `10-foundation` env |
| 2 | `20-identity` shared (once), then env, then every domain |
| 3 | `25-access` |
| 4 | Manual, once: claim the Databricks account, make `piq-metastore-admins` the metastore admin, add every Terraform identity as account admin |
| 5 | `30-account` shared (once), then env, then every domain |
| 6 | `40-unity-catalog` shared (once; needs stack 30 finished for **every** environment, because its tag-assigner rules name every environment's groups; re-run it when an environment is added), then env (creates the storage credential), then every domain |
| 7 | `50-workspace` env, then every domain; then `55-ai-platform` env and domains |
| 8 | `60-governance` env (creates the masking functions), then every domain |
| 9 | `70-observability` env, prod environment only |

Adding a domain: `10-foundation` env (new storage container) → `20-identity` domain:new →
`30-account` domain:new → `30-account` env (resolves the groups named by the vault grants) →
`40-unity-catalog` env (vault grants for the new domain) → `40-unity-catalog` domain:new →
`50`, `55`, `60` domain:new → `25-access` (approvals).

## 15. Entitlements: who is in which group

Two jobs are kept apart:

| Job | Where |
|---|---|
| **Define** the groups and what each may do on data | This repo: stacks 20, 40, 50, 55, 60 |
| **Put people into groups** and record which access requests were approved | `config/entitlements/<env>/`, applied only by stack `25-access` |

An **entitlement** is a fact such as "jane is a data-analyst in prd" or "exec_reporting may
read `loss_ratio` in prd". Organisations normally keep these in an identity-governance tool
(SailPoint, Saviynt, PingID). This platform has none yet, so `config/entitlements/<env>/` is the
stand-in:

| File | Holds |
|---|---|
| `personas.yaml` | `<upn>: [persona, ...]`; a domain persona is `<domain>/<persona>` |
| `product_access.yaml` | `<product>: [consumers]` (consumer domains only in the prod environment) |
| `sars.yaml` | `members: { <sar>: [group references] }` |
| `sandboxes.yaml` | Personal sandbox users (nonprod only) |
| `experiments.yaml` | Approved experiments (prod only) |
| `admins.yaml` | `domains: { <domain>: [upn] }`, members of `piq-{env}-{domain}-dbadmin` |

The stacks that create groups never add people. The sandbox and experiment schemas
themselves (`u_{user}`, `exp_{name}`) are still created by stack 40's `env` scope from these
files, because they are Unity Catalog objects.

**Handing over to an IAM tool:** delete `config/entitlements/` and stack `25-access`. The tool
manages the same Entra groups. The group **names** (section 5, produced by the naming module)
are the contract; nothing else changes. `scripts/provision_access.py` and the
`provision-access` workflow write these files, so they go away at the same time.

## 16. Domain shape and domain access: standard plus additions

Every domain gets the **standard**: the schemas in `config/domains.yaml`, the roles in
`config/access_matrix.yaml` and the global personas in `config/personas.yaml`. A domain can add
to or trim the standard using two optional files, split by who decides:

| File | Approved by | Declares |
|---|---|---|
| `config/domain_shape/<domain>.yaml` | The domain team | Schemas to add (`layer`, `comment`) or remove, extra roles (`service_principal_only` optional), domain personas (name and description) |
| `config/domain_access/<domain>.yaml` | Platform and governance | What each role may do on each schema, access to product schemas, `warehouse` `CAN_USE` / `CAN_MANAGE` extras, and each domain persona's `access` per environment |

Declaring a schema, role or persona grants nothing. Access is decided in the second file. For
example, claims could add a schema `adjuster_notes` and a role `adjuster` in the first file, and
allow `adjuster` to read it in the second.

Limits (checked by `scripts/validate_config.py` and by the naming module):

- A bundle can never exceed `override_ceiling` in `access_matrix.yaml` (`RWC`), so no override
  can grant `ALL_PRIVILEGES` or `MANAGE`.
- The `admin` schema cannot be removed or given access.
- Names must not collide: an extra role cannot reuse a standard role or `writer`; an extra
  schema cannot reuse a standard name or start with `product_`; a domain persona cannot reuse a
  global persona name.
- A domain persona can only reference roles of its own domain (not the vault, not other domains).
- A bundle can be `{ nonprod: ..., prod: ... }`.
- The wildcard `dev:*:analyst` means "every domain that defines the role".

Schema names stay free of environments, so a new schema reaches prd by promoting a release.

## 17. Terraform identities and what they can and cannot do

Terraform signs in as a service principal through GitHub OIDC; no secret exists. `bootstrap/`
(run once, locally) creates:

| Object | Purpose |
|---|---|
| `rg-piq-{env}` per environment | A resource group per environment (stack 10 only looks it up) |
| `sp-piq-terraform` | The shared identity: `shared` scope and account-wide work |
| `sp-piq-terraform-{env}` per environment | Azure `Contributor` and `Role Based Access Control Administrator` **limited to that environment's resource group** |

Each identity trusts only specific GitHub environments (OIDC subjects):

| Identity | Trusted GitHub environments |
|---|---|
| `sp-piq-terraform-{env}` | `{env}` (apply), `{env}-plan` (plan) |
| `sp-piq-terraform` | `shared`, `shared-plan` |

`deploy.yml` plans in `{env}-plan` (no reviewers) and applies in `{env}` (required reviewers on
the prod environment).

**What this protects, and what it does not.**

| Protected | Not protected |
|---|---|
| The dev identity cannot create or change Azure resources in `rg-piq-prd` | Microsoft Entra (Graph) permissions are tenant-wide: a dev identity could technically edit prd groups. Only the pipeline rules stop it. Entra administrative units (CR-001) would close this. |
| Each GitHub environment can only sign in as its own identity | Databricks account admin cannot be limited per environment |
| | The state storage account is shared: any identity can read or write any state file. Separate state containers per environment would close this. |

## 18. What has been verified

Nothing in sections 13 to 17 has been applied to real Azure, Entra or Databricks. It is
covered by checks that need no cloud access:

| Check | What it proves |
|---|---|
| `make test` (`tests/naming/run_tests.py`) | Names, groups, grants, nesting, masks; every negative rule is rejected by both the naming module and the validator; the **partition test**: every item belongs to exactly one scope and the scopes together cover everything |
| `tests/wrappers/run_tests.py` | State keys, the scope check, the promotion gate (including a graph of environments), release tags, `apply.py` refusals |
| `make plan-test` | A mocked plan of every stack for every target. The resources planned across all of a stack's targets add up to the same count as one plan of the whole stack (for example 347 for stack 40), so splitting lost and duplicated nothing |
| `terraform validate` | Every stack and `bootstrap/` |

Not yet proven: real provider behaviour (for example that the per-environment resource group
rights are enough to create a Databricks workspace), the GitHub environments and OIDC setup,
and the deploy records in blob storage.
