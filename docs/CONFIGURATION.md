# Configuration reference

All behaviour comes from `config/`. `modules/naming` reads every file; each
stack uses what it needs. After any edit: `make test`.

| File | Owns | Stacks |
|---|---|---|
| `platform.yaml` | prefix, suffix, Azure IDs, region, state backend, GitHub org, per-env network, IP lists, egress, `identity.resolve_consumer_leads` | all |
| `domains.yaml` | producer domains (repo, admins, anon, lakebase, app_space), private schemas, vault (sources, schemas), anon schemas, reserved names | 10, 20, 30, 40, 55, 60 |
| `products/<domain>.yaml` | products of that domain: type, description, contract, status, consumers | 20, 40 |
| `consumers/<consumer>.yaml` | consumer domain: lead, roles, prep catalog and schemas, warehouse | 10, 20, 30, 40, 50 |
| `access_matrix.yaml` | roles, bundles (R, RW, RWC, O), catalog-level grants, domain/product/vault/consumer/anon matrices, SP-only roles | 40 |
| `sars.yaml` | sensitive access roles: masks unlocked, member groups per env | 20, 60 |
| `governed_tags.yaml` | tag taxonomy, assigners, masks (tag, value, function) | 40, 60 |
| `workspace_objects.yaml` | warehouse sizes per scope, compute policies, vector search | 50, 55 |
| `personas.yaml` | personas and platform groups | 20, 30 |
| `service_principals.yaml` | extra service principals (deployers and loaders are generated) | 20, 30 |
| `cost.yaml` | budgets per environment, domain, vault, consumer, AI Gateway | 30 |
| `sandbox_users.yaml`, `experiments.yaml` | personal dev sandboxes, approved prd experiments | 20, 30, 40 |
| `test_users.yaml` | training-only Entra users and their memberships | 20 |

## Group references

Used in `personas.yaml`, `service_principals.yaml`, `sars.yaml`, `test_users.yaml`:

| Reference | Resolves to |
|---|---|
| `dev:claims:producer` | one local role |
| `prd:*:analyst` | that role in every producer domain |
| `vault:dev:engineer` | vault engineers in dev |
| `consumer:exec_reporting:analyst` | a consumer group (prd) |
| `persona:data-engineer` | a persona group |
| `mesh-governance` | a platform group |

## Products

```yaml
# config/products/profitability.yaml
products:
  loss_ratio:
    type: data                 # data | agent | app
    description: Loss ratio by line, state and accident year
    contract: docs/contracts/loss_ratio.md
    status: published          # draft | published | deprecated
    consumers: [exec_reporting]  # other domains or consumer domains
```

The file name is the owning domain. Product names are unique across files.
Consumers may not include the owning domain, and domains may not depend on
each other in a cycle.

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
in Entra; until then their groups are owned by Terraform only.

## SARs

```yaml
# config/sars.yaml
sars:
  financial_metrics:
    description: Unmasked sensitive financial metrics
    unlocks: [financial_amount]          # mask keys from governed_tags.yaml
    members:
      prd: ["consumer:exec_reporting:analyst"]
```

## Derived names

| Thing | Pattern | Example |
|---|---|---|
| Workspace | `dbw-{prefix}-{env}` | `dbw-piq-prd` |
| Storage account | `st{prefix}{env}lake{suffix}` | `stpiqprdlakea1b2` |
| Storage container | catalog owner, hyphenated | `policy-financial`, `claims-anon` |
| Catalog | `{env}_{domain}`, `{env}_vault`, `prd_{consumer}`, `prd_{domain}_anon` | `prd_policy_financial` |
| Product schema | `product_{name}` | `product_earned_premium` |
| Local role group | `{prefix}-{env}-{domain-hyphen}-{role}` | `piq-dev-policy-financial-analyst` |
| Product group | `{prefix}-{env}-product-{name-hyphen}` | `piq-prd-product-loss-ratio` |
| Consumer group | `{prefix}-prd-{consumer-hyphen}-{role}` | `piq-prd-exec-reporting-analyst` |
| SAR group | `{prefix}-{env}-sar-{name-hyphen}` | `piq-prd-sar-financial-metrics` |
| Deployer | `sp-{prefix}-{env}-{domain-hyphen}-deploy` | `sp-piq-prd-claims-deploy` |
| Warehouse | `piq-{domain}-transform`, `piq-vault-load`, `piq-{consumer}-bi`, `piq-shared` | `piq-claims-transform` |
| Usage policy | `{prefix}-{env}-{owner}` | `piq-prd-exec-reporting` |
| App Space | `{prefix}-{domain-hyphen}` | `piq-claims` |
