# Configuration reference

All behaviour comes from `config/`. `modules/naming` reads every file; each
stack uses what it needs. After any edit: `make validate` and `make test`.

**Environment names (`dev`, `prd`) are labels.** Rules depend on an environment's
**tier** (`nonprod` or `prod`), see [Environments](#environments).

**Scopes.** Every item is owned by one scope (`shared`, `env`, `access` or
`domain:<name>`) and each scope is deployed on its own. See `docs/CONCEPTS.md`.
The "Stacks" column below says which stacks read a file.

| File | Owns | Approved by | Stacks |
|---|---|---|---|
| `platform.yaml` | prefix, suffix, Azure IDs, region, state backend, GitHub org, environments (tier, promotes_from, allow_hotfix, network, IP lists, egress), `identity.resolve_consumer_leads` | platform | all |
| `domains.yaml` | producer domains (repo, anon, lakebase, app_space), the **standard** private schemas, vault (sources, schemas), anon schemas, reserved names | platform + vault team | all stacks that use naming |
| `domain_shape/<domain>.yaml` | what one domain adds: extra schemas (or removes a standard one), roles, personas. Optional | the domain team | 20, 40, 50, 60 |
| `domain_access/<domain>.yaml` | what one domain's roles may do: schema and product access, warehouse use, domain persona access per environment. Optional | platform + governance | 20, 40, 50 |
| `products/<domain>.yaml` | products of that domain: type, description, contract, status | the producing domain | 20, 40 |
| `consumers/<consumer>.yaml` | consumer domain: lead, roles, prep catalog and schemas, warehouse | the consumer lead | 20, 30, 40, 50 |
| `access_matrix.yaml` | roles, bundles (R, RW, RWC, O), bundle order and ceiling, catalog-level grants, domain/product/vault/consumer/anon matrices, SP-only roles | platform + governance | 40 |
| `personas.yaml` | global personas (access per environment) and platform groups | platform + governance | 20, 30 |
| `sars.yaml` | sensitive access roles: the masks each unlocks (no members) | governance | 20, 60 |
| `governed_tags.yaml` | tag taxonomy, assigners, masks (tag, value, function) | governance | 40, 60 |
| `workspace_objects.yaml` | warehouse sizes per scope, compute policies, vector search | platform | 50, 55 |
| `service_principals.yaml` | extra service principals (deployers and loaders are generated) | platform | 20, 30 |
| `cost.yaml` | budgets per environment, domain, vault, consumer, AI Gateway | platform | 30 |
| `entitlements/<env>/*.yaml` | who is in which group and which approvals are given, per environment (see below) | platform; stricter for prod | 25 (and 40 for sandbox and experiment schemas) |
| `test_users.yaml` | training-only Entra users and their memberships | platform | 20, 25 |

## Environments

```yaml
# config/platform.yaml
environments:
  dev:
    tier: nonprod          # nonprod | prod. Exactly one environment must be prod
    promotes_from: []      # environments a release must be deployed to first; [] = accepts any commit
    allow_hotfix: false    # true = a hotfix release may skip promotes_from (named approver required)
    network: { ... }
  prd:
    tier: prod
    promotes_from: [dev]
    allow_hotfix: true
    network: { ... }
```

- Names are 2 to 8 lowercase letters or digits, starting with a letter.
- `promotes_from` may list several environments (a release must have reached **all** of
  them) and cannot form a cycle. Example: `qa: promotes_from: [dev1, dev2]`.
- **Adding an environment** is config only: add an entry here (with a `network` block),
  then add its entries to `platform_groups` in `personas.yaml` that name an environment
  (`sandbox-users` workspaces, for example) and an `access` line per persona.
  `<env>-workspace-admins` is generated for you.

What the tier decides:

| Rule | Tier |
|---|---|
| Humans cannot join service-principal-only roles (`service_principal_only_in_prod` in `access_matrix.yaml`, plus extra roles flagged `service_principal_only`) | prod |
| Consumer domains, the anonymized catalogs' writer, approved experiments | prod |
| Personal sandboxes | nonprod |
| Anonymized data readable from the environment | nonprod |
| `vault.overrides` in `access_matrix.yaml` (keys are tiers, not names) | per tier |
| Compute policies with `nonprod_only: true` are skipped | prod |

## Group references

Used in `personas.yaml` (`access`), `service_principals.yaml`, entitlement SAR files,
`test_users.yaml`:

| Reference | Resolves to |
|---|---|
| `dev:claims:producer` | one local role of one domain |
| `prd:*:analyst` | that role in every domain that **defines** it |
| `vault:dev:engineer` | vault engineers in dev |
| `consumer:exec_reporting:analyst` | a consumer group (prod environment) |
| `persona:dev:data-engineer` | a global persona group in dev |
| `persona:prd:claims:adjuster-analyst` | a domain persona group in prd |
| `mesh-governance` | a platform group |
| `dev-workspace-admins` | the generated workspace-admin group of an environment |

In a persona's `access.<env>` list, an environment prefix must be that same `<env>`,
`vault:<env>:...` must match, and a platform group must be assigned to that
environment's workspace (its `workspaces:` in `personas.yaml`). A domain persona may
only reference its own domain's roles.

## Personas

```yaml
# config/personas.yaml
personas:
  data-engineer:
    description: Builds domain pipelines and products in dev; read-only in prd
    access:
      dev: ["dev:*:producer", "sandbox-users"]
      prd: ["prd:*:analyst"]          # [] = no access in that environment
```

Every environment needs an `access` entry (use `[]` for none). One Entra group is
created per persona per environment: `piq-dev-persona-data-engineer`,
`piq-prd-persona-data-engineer`. **Who holds a persona is not here**, it is an
entitlement (below).

## Domain shape and access

Optional files per domain. Everything not mentioned follows the standard.

```yaml
# config/domain_shape/claims.yaml   (domain team)
schemas:
  add:
    adjuster_notes: { layer: INFO_MART, comment: "Free-text adjuster notes" }   # volumes: [..] optional
  remove: [ai]                          # a standard schema this domain does not want (never admin)
roles:
  adjuster:                             # creates piq-<env>-claims-adjuster in every environment
    description: Claims adjusters
    service_principal_only: false       # true = in the prod environment only service principals may join
personas:
  adjuster-analyst:                     # creates piq-<env>-persona-claims-adjuster-analyst
    description: Adjuster who analyses claims data
```

```yaml
# config/domain_access/claims.yaml   (platform + governance)
schemas:                                # schema -> role -> bundle
  reporting: { analyst: R }             # tighter than the standard row, for this domain only
  adjuster_notes: { producer: RWC, adjuster: R }
  info_mart:
    analyst: { nonprod: RW, prod: R }   # a bundle may differ by tier
product:                                # extra roles' access to product schemas (merged with access_matrix.product)
  adjuster: R
warehouse:                              # extra roles on the domain warehouse
  CAN_USE: [adjuster]
  CAN_MANAGE: []
personas:                               # access of each domain persona, per environment
  adjuster-analyst:
    access:
      dev: ["dev:claims:adjuster", "sandbox-users"]
      prd: ["prd:claims:adjuster"]
```

Rules (the validator and the naming module both check them):

- Schema, role and persona names must be valid (schema and role snake_case, persona
  lowercase with hyphens), must not collide with standard or reserved names (`writer`,
  `dbadmin`, a global persona) and a schema must not start with `product_`.
- A schema `layer` must be a known layer; every added schema needs a `comment`.
- `admin` cannot be removed and has no access override.
- No bundle may exceed `override_ceiling` in `access_matrix.yaml` (`RWC`).
- Access can only name roles the domain has, and only schemas it has.
- A domain persona may only reference its own domain's roles (no vault, no other domain).
- The files must be named after an existing domain.

## Access matrix additions

```yaml
# config/access_matrix.yaml (new and changed keys)
bundle_order: [R, RW, RWC, O]          # weakest to strongest; used for the ceiling
override_ceiling: RWC                  # no domain override may exceed this
service_principal_only_in_prod: [producer]
vault:
  overrides:
    nonprod: { engineer: RWC }         # keyed by tier
anon: { writer: RWC, nonprod_readers: R }
# A bundle value in any matrix may be a plain name, or differ by tier:
#   reporting: { analyst: { nonprod: RW, prod: R } }
```

`workspace_objects.yaml` compute policies use `nonprod_only: true` (formerly `dev_only`).

## Entitlements

One folder per environment: `config/entitlements/<env>/`. These files are the stand-in
for an identity-governance tool. Only stack `25-access` turns them into memberships
(plus sandbox and experiment schemas, which stack 40's `env` scope reads). A missing
file means nothing. To hand the job to an IAM tool, delete the folder and stack 25;
the group **names** are the contract.

| File | Content | Notes |
|---|---|---|
| `personas.yaml` | `users: { <upn>: [persona, ...] }` | `persona` is a key of `personas.yaml`, or `<domain>/<persona>` for a domain persona |
| `product_access.yaml` | `products: { <product>: [domain or consumer, ...] }` | approved by the producing domain; a consumer domain only in the prod environment |
| `sars.yaml` | `members: { <sar>: [group reference, ...] }` | approved by governance |
| `sandboxes.yaml` | `users: [{ upn, requested_via }]` | nonprod only; creates `<env>_sandbox.u_<localpart>` |
| `experiments.yaml` | `experiments: [{ name, description, members, approved_by, ticket, expires }]` | prod only; creates `<env>_sandbox.exp_<name>` |
| `admins.yaml` | `domains: { <domain>: [upn, ...] }` | members of `piq-<env>-<domain>-dbadmin` |

A person can hold different personas in dev and prd: list them in each environment's
`personas.yaml`. `scripts/provision_access.py` edits these files from an approved
request (it always needs `--env`).

## Products

```yaml
# config/products/profitability.yaml
products:
  loss_ratio:
    type: data                 # data | agent | app
    description: Loss ratio by line, state and accident year
    contract: docs/contracts/loss_ratio.md
    status: published          # draft | published | deprecated
```

The file name is the owning domain. Product names are unique across files.
**Who may read a product** is an entitlement (`entitlements/<env>/product_access.yaml`):
consumers may not include the owning domain, and domains may not depend on each
other in a cycle.

## Consumers

```yaml
# config/consumers/exec_reporting.yaml
description: Executive reporting and board packs
lead: lead@yourtenant.onmicrosoft.com  # Entra owner of the consumer groups
roles: [analyst, developer]
prep_catalog: true
prep_schemas: [staging, prep, reporting]
warehouse: { size: 2X-Small, max_clusters: 2, auto_stop_mins: 10 }
```

Set `identity.resolve_consumer_leads: true` in `platform.yaml` once leads exist
in Entra; until then their groups are owned by Terraform only. The lead adds members
directly in Entra; Terraform never manages consumer-group membership.

## SARs

```yaml
# config/sars.yaml  (definition only)
sars:
  financial_metrics:
    description: Unmasked sensitive financial metrics
    unlocks: [financial_amount]          # mask keys from governed_tags.yaml
```

```yaml
# config/entitlements/prd/sars.yaml  (membership)
members:
  financial_metrics: ["consumer:exec_reporting:analyst"]
```

## Derived names

`{prod}` is the name of the prod-tier environment (`prd` today).

| Thing | Pattern | Example |
|---|---|---|
| Workspace | `dbw-{prefix}-{env}` | `dbw-piq-prd` |
| Resource group | `rg-{prefix}-{env}` (created by bootstrap) | `rg-piq-prd` |
| Storage account | `st{prefix}{env}lake{suffix}` | `stpiqprdlakea1b2` |
| Storage container | catalog owner, hyphenated | `policy-financial`, `claims-anon` |
| Catalog | `{env}_{domain}`, `{env}_vault`, `{prod}_{consumer}`, `{prod}_{domain}_anon` | `prd_policy_financial` |
| Product schema | `product_{name}` | `product_earned_premium` |
| Local role group | `{prefix}-{env}-{domain-hyphen}-{role}` | `piq-dev-policy-financial-analyst` |
| Product group | `{prefix}-{env}-product-{name-hyphen}` | `piq-prd-product-loss-ratio` |
| Consumer group | `{prefix}-{prod}-{consumer-hyphen}-{role}` | `piq-prd-exec-reporting-analyst` |
| SAR group | `{prefix}-{env}-sar-{name-hyphen}` | `piq-prd-sar-financial-metrics` |
| Persona group | `{prefix}-{env}-persona-{name}` | `piq-dev-persona-data-engineer` |
| Domain persona group | `{prefix}-{env}-persona-{domain-hyphen}-{name}` | `piq-prd-persona-claims-adjuster-analyst` |
| Workspace admins | `{prefix}-{env}-workspace-admins` (generated) | `piq-prd-workspace-admins` |
| Deployer | `sp-{prefix}-{env}-{domain-hyphen}-deploy` | `sp-piq-prd-claims-deploy` |
| Terraform identity | `sp-{prefix}-terraform` (shared), `sp-{prefix}-terraform-{env}` | `sp-piq-terraform-prd` |
| Warehouse | `piq-{domain}-transform`, `piq-vault-load`, `piq-{consumer}-bi`, `piq-shared` | `piq-claims-transform` |
| Usage policy | `{prefix}-{env}-{owner}` | `piq-prd-exec-reporting` |
| App Space | `{prefix}-{domain-hyphen}` | `piq-claims` |
| State key | `{stack}/shared.tfstate`, `{stack}/{env}/{env,access}.tfstate`, `{stack}/{env}/domain-{name}.tfstate` | `40-unity-catalog/prd/domain-claims.tfstate` |
| Release tag | `rel-YYYY.MM.DD.N` | `rel-2026.10.23.1` |
