# Databricks Mesh Platform

Enterprise Azure Databricks platform for your org, provisioned entirely as
code: Azure infrastructure, Entra ID identities, the Databricks account, Unity
Catalog, workspaces, AI/app infrastructure, governance and observability.

It implements the **mesh architecture**: a shared enterprise raw vault
(Data Vault 2.0), producer domains that publish data, agent and app products,
consumer-only domains, and Sensitive Access Roles (SARs). Everything is driven
by YAML in `config/`: publishing a product, approving a consumer or granting a
SAR is a pull request that edits one file.

> **Status:** written and tested without cloud access, not yet applied.
> `make test` checks the naming module (27 positive, 6 negative cases).
> `make plan-test` runs a mocked `plan` of every stack: all six Databricks
> stacks plan cleanly against the real provider schema (v1.137); the Azure
> stacks (bootstrap, 10, 20) were checked against the azurerm v5 / azuread v3
> docs and plan in CI where those providers install. Expect a few first-run
> fixes; see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## What this entails

| Layer | Result |
|---|---|
| Environments | `dbw-piq-dev` and `dbw-piq-prd`, VNet-injected, no public IPs, Premium. Producers and consumers share each environment's workspace |
| Raw vault | `{env}_vault`: landing, staging per source, raw vault, shared business vault; written only by the vault loader |
| Domains | `claims`, `policy_financial`, `profitability`: one catalog `{env}_{domain}` each, with private schemas and `product_{name}` schemas |
| Products | Loss, Earned premium, Loss ratio (derived). One schema and one Entra group per product; consumers are nested into it |
| Consumers | `exec_reporting`: consumer groups owned by its lead, optional prep catalog `prd_exec_reporting`, its own warehouse |
| Sensitive data | ABAC masks on every domain, vault and consumer catalog; only SAR groups and data writers are exempt |
| Cross-environment | `prd_claims_anon`: irreversibly anonymized prd data, bound read-only to dev |
| Identity | Entra groups and service principals via automatic identity management; per-domain deployers with GitHub OIDC; no secrets, no PATs |
| Compute | Dedicated serverless warehouse per producer domain, consumer domain and the vault; one shared warehouse |
| Cost | `piq_env` / `piq_domain` tags on every warehouse and serverless DBU; budgets per environment, domain, vault and consumer |
| Observability | Cost, query, job, audit, PII, lineage and product-catalog views over system tables |

## Repository layout

```
config/                  YAML that drives everything (start with platform.yaml)
  products/<domain>.yaml   products of each domain (owned by that domain via CODEOWNERS)
  consumers/<name>.yaml    consumer-only domains (owned by their lead)
bootstrap/               one-time, run locally: state storage, Terraform SP, GitHub OIDC
modules/naming/          derives every name, group, grant, warehouse and policy from config/
modules/uc_environment/  Unity Catalog objects for one environment
modules/workspace_config/ settings, warehouses, compute policies for one workspace
modules/ai_platform/     vector search, App Spaces, Lakebase for one environment
stacks/10..70            layered Terraform stacks, one state file each
sql/                     masking functions, observability views, lab scripts
scripts/                 tf.sh, run_sql.py, validate_config.py, provision_access.py
templates/domain-bundle/ starter domain repo: Asset Bundle + dbt, env-free code
templates/obo-app/       on-behalf-of-user Databricks App
tests/naming/            naming module and validator tests
tests/stacks/            mocked plans of every stack
docs/                    architecture, runbook, operations, configuration, decisions, troubleshooting
.github/                 validate, plan, apply, provision-access workflows; CODEOWNERS
```

## Quick start

Follow [docs/RUNBOOK.md](docs/RUNBOOK.md) the first time. In short:

```bash
pip install -r requirements.txt
make test                                    # after editing config/platform.yaml
cd bootstrap && terraform init && terraform apply   # once, as yourself
# then stacks 10 -> 70 through the apply workflow (or ./scripts/tf.sh locally)
```

## Stack order

| Order | Stack | Needs | Re-run when |
|---|---|---|---|
| 1 | 10-foundation | bootstrap | networking, storage, domains, consumers, anon flags change |
| 2 | 20-identity | 10 | personas, products, consumers, SARs, service principals change |
| – | *Phase 4 manual step* | 10, 20 | once: claim account, set metastore admin |
| 3 | 30-account | 10, 20 | group/SP changes, budgets, usage policies, egress |
| 4 | 40-unity-catalog | 10, 30 | domains, schemas, products, consumers, matrix, tags, sandboxes |
| 5 | 50-workspace | 10, 40 | warehouses, policies, IP lists |
| 6 | 55-ai-platform | 10, 30 | App Spaces, vector search, Lakebase |
| 7 | 60-governance | 10, 50 | masks, SARs, sensitive tags |
| 8 | 70-observability | 10, 50 | platform views |

## Rules this repo enforces

1. Humans never write prd data: prd producer and writer groups hold only deploy service principals.
2. Products read products: a derived product never reads another domain's private schemas.
3. Product groups get `USE CATALOG` without `BROWSE`: consumers see only the product schemas they were approved for.
4. Masks exempt only SAR groups and the identities that write the data.
5. The environment appears only in names whose scope spans environments: workspaces, catalogs, groups, service principals, usage policies. Never in schemas or workspace objects, and never in code.
6. Production data reaches dev only anonymized, through a read-only `prd_{domain}_anon` catalog.
7. Nobody has direct storage access, personal access tokens are off, and CI holds no secrets.
8. Product approvals belong to the producing domain, SARs and tags to governance, consumer membership to the consumer lead.

## Documentation

| Document | Use it for |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the platform is designed and why |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | First-time setup, step by step, with verification |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Publishing products, approving consumers, SARs, onboarding, new domains |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every config file and field |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Architecture decision records |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Expected first-run problems and fixes |
