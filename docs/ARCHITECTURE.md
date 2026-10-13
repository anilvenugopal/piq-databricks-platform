# Architecture

What the platform is and why each choice was made. For the steps to build it,
see [RUNBOOK.md](RUNBOOK.md); for day-2 procedures, [OPERATIONS.md](OPERATIONS.md).

## 1. Topology

```
Microsoft Entra ID ──(automatic identity management)──┐
  users, groups, service principals                    ▼
GitHub Actions ──(OIDC)──> sp-piq-terraform ──> Databricks account
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
| Consumer domain | exec_reporting | optional `prd_{consumer}` | Nothing | Products it is approved for |

A **product** is one schema `product_{name}` in its domain's catalog (tables,
views, functions, models or agents; apps run in the domain's App Space) and one
Entra group `piq-{env}-product-{name}`. Publishing is an entry in
`config/products/<domain>.yaml`. Approving a consumer adds it to the product's
`consumers` list; Terraform nests the consumer's groups into the product group.
Consumer domains exist in prd only.

Derived products read **products**, never another domain's private schemas, so
a domain can change anything behind its contract. Each product's `consumers`
list is its impact list; Unity Catalog lineage shows the chain.

## 3. Catalogs and schemas

| Catalog | Schemas |
|---|---|
| `{env}_vault` | `landing` (volumes), `stage_{source}`, `raw_vault`, `business_vault_core`, `admin` |
| `{env}_{domain}` | private: `admin`, `business_vault`, `info_mart`, `reporting`, `sandbox`, `ai`, `event_log`; products: `product_{name}` |
| `prd_{consumer}` | `staging`, `prep`, `reporting` |
| `prd_{domain}_anon` | `data` |
| `{env}_platform` | `governance` (mask functions), `audit`, `monitoring`, `observability` |
| `{env}_sandbox` | `u_{user}` (dev), `exp_{name}` (prd) |

Bindings: every catalog is bound read-write to its environment's workspace.
`prd_{domain}_anon` is also bound read-only to dev. Nothing else crosses.

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
| Local roles | `piq-{env}-{domain}-{producer, analyst, ai, dbadmin}` | Domain team access |
| Writer | `piq-{env}-{domain}-writer` | The domain deployer; exempt from masks |
| Vault | `piq-{env}-vault-{engineer, writer}` | Vault team; writer holds the loader |
| Product | `piq-{env}-product-{name}` | Readers of one product |
| Consumer | `piq-prd-{consumer}-{role}` | Consumer domain; owned and populated by its lead |
| SAR | `piq-{env}-sar-{policy}` | Sensitive access; members approved by governance |
| Platform | `piq-{name}` | mesh-admins, metastore-admins, workspace admins, mesh-governance, monitoring, sandbox |
| Persona | `piq-persona-{name}` | Job personas nested into the groups above |

Service principals: `sp-piq-{env}-{domain}-deploy` per domain (member of its
producer and writer groups), `sp-piq-{env}-vault-loader`, plus extras in
`service_principals.yaml`. All authenticate with GitHub OIDC, scoped to
`repo:<org>/<repo>:environment:<env>`. In prd, producer groups contain only
deployers: humans read prd and change it through CI.

## 6. Access model

Privilege bundles (`config/access_matrix.yaml`):

| Bundle | Privileges |
|---|---|
| R | `USE_SCHEMA`, `SELECT`, `EXECUTE`, `READ_VOLUME` |
| RW | R + `MODIFY`, `WRITE_VOLUME` |
| RWC | RW + `CREATE_TABLE`, `CREATE_MATERIALIZED_VIEW`, `CREATE_FUNCTION`, `CREATE_VOLUME`, `CREATE_MODEL` |
| O | `ALL_PRIVILEGES`, `MANAGE`: the grantable equivalent of ownership |

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

- SAR groups that unlock that mask (`config/sars.yaml`), in every catalog;
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
| `piq-{consumer}-bi` (prd) | that consumer's groups | `piq_domain = {consumer}` |
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
| Group, service principal | Yes | `piq-prd-claims-producer` |
| Usage policy, budget | Yes | `piq-prd-claims` |
| Schema, table, function, volume | No | `prd_claims.product_loss.loss_triangle` |
| Warehouse, job, app, App Space | No | `piq-claims-transform` |

Code never contains an environment: bundles pass `env`, dbt tasks set
`catalog = {env}_{domain}`, SQL uses `IDENTIFIER(:env || '_claims...')`,
notebooks read `env` from a job parameter.

## 10. Network and security

VNet injection with no public IPs; optional NAT for classic egress; IP access
lists (off by default, incompatible with GitHub-hosted runners); serverless
egress policies (prd restricted, dry run first); PATs disabled; storage shared
keys disabled. Private Link and customer-managed keys are later hardening steps.

## 11. AI and apps

Each domain has an `ai` schema and an App Space; agents and apps that are
products keep their tables, functions and registered models in their product
schema. Apps and agents query data on behalf of the caller (template
`templates/obo-app`), so masks and grants apply to the person. Vector Search
endpoints are per environment; index access is data access. AI spend has its
own budget; outbound calls are limited by serverless egress policies.

## 12. Observability

Views in `prd_platform` over system tables: cost by env and domain, untagged
usage, query activity, job outcomes, denied requests, permission changes, PII
columns, lineage, and the product catalog (`governance.products`).
