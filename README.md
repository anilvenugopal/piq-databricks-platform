# piq-databricks-platform

Enterprise Azure Databricks platform for PremiumIQ, provisioned entirely as code:
Azure infrastructure, Entra ID identities, the Databricks account, Unity Catalog,
workspace configuration, AI/app infrastructure, governance and observability.

Everything is driven by YAML in `config/`. Adding a domain, a person, a sandbox or
an experiment is a pull request that edits one file.

> **Status:** written and statically validated, not yet applied to a live account.
> The six Databricks stacks pass `validate` against the Databricks provider schema
> (v1.137). The Azure stacks pass `fmt` and were checked argument-by-argument against
> the azurerm v5 / azuread v3 docs. Expect a few first-run fixes; see
> [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## What you get

| Layer | Result |
|---|---|
| Environments | `dev` and `prd` workspaces, VNet-injected, no public IPs, Premium tier |
| Storage | One ADLS Gen2 account per environment, one container per catalog, accessed only through Unity Catalog |
| Identity | Entra ID groups (functional, persona, platform) and service principals, synced automatically; no SCIM, no PATs, no secrets for CI |
| Data | `{env}_{domain}` catalogs with medallion schemas, `{env}_sandbox`, `{env}_platform`; each bound to its own workspace |
| Access | Your LAYER x ROLE matrix expanded into Unity Catalog grants; prd writes by service principals only |
| Governance | Governed tag taxonomy, ABAC column masks for PII, data classification |
| Cost | Usage policies tag all serverless spend by env x domain; budgets per env, domain and AI Gateway |
| Network | VNet injection, optional NAT, IP access lists, serverless egress policies |
| AI and apps | Vector Search endpoints, App Spaces per domain, optional Lakebase, an on-behalf-of-user app template |
| Observability | Cost, query, job, audit, PII and lineage views over system tables |

## Repository layout

```
config/                 YAML that drives everything (start with platform.yaml)
bootstrap/              one-time, run locally: state storage, Terraform SP, GitHub OIDC
modules/naming/         derives every name, group, grant and assignment from config/
modules/uc_environment/ Unity Catalog objects for one environment
modules/workspace_config/ settings, warehouses, compute policies for one workspace
modules/ai_platform/    vector search, app spaces, Lakebase for one environment
stacks/10-foundation    Azure: RGs, VNets, workspaces, storage, access connectors, Key Vault
stacks/20-identity      Entra: groups, nesting, service principals, test users
stacks/30-account       Databricks account: identity sync, assignments, usage policies, budgets, egress
stacks/40-unity-catalog tags, credentials, external locations, catalogs, schemas, volumes, grants
stacks/50-workspace     workspace settings, SQL warehouses, compute policies, system tables
stacks/55-ai-platform   vector search, app spaces, Lakebase projects
stacks/60-governance    masking functions, ABAC policies, data classification
stacks/70-observability platform views over system tables
sql/                    governance functions, observability views, lab scripts
scripts/                tf.sh wrapper, SQL runner, config validator, access provisioning
templates/obo-app/      Asset Bundle for an on-behalf-of-user Databricks App
docs/                   architecture, runbook, operations, decisions, troubleshooting, config reference
.github/                CI: validate, plan, apply, provision-access; CODEOWNERS
```

## Quick start

Follow [docs/RUNBOOK.md](docs/RUNBOOK.md) end to end the first time. In short:

```bash
pip install -r requirements.txt
python3 scripts/validate_config.py          # after editing config/platform.yaml

cd bootstrap && terraform init && terraform apply   # once, as yourself
# GitHub: add repo variables from `terraform output github_variables`,
# create environment "platform" with yourself as required reviewer

./scripts/tf.sh 10-foundation init && ./scripts/tf.sh 10-foundation plan -out tfplan
./scripts/tf.sh 10-foundation apply tfplan
# claim the Databricks account (runbook Phase 4), then stacks 20 -> 70 in order
```

After bootstrap, all applies run from GitHub Actions (`apply` workflow), gated by
the `platform` environment approval.

## Stack order and dependencies

| Order | Stack | Needs | Re-run when |
|---|---|---|---|
| 1 | 10-foundation | bootstrap | network, storage or workspace settings change |
| 2 | 20-identity | 10 | personas, members, service principals change |
| - | *Phase 4 manual step* | 10, 20 | once: claim account, set metastore admin |
| 3 | 30-account | 10, 20 | assignments, budgets, usage policies, egress change; after new users |
| 4 | 40-unity-catalog | 10, 30 | domains, schemas, matrix, tags, sandboxes, experiments change |
| 5 | 50-workspace | 10, 40 | warehouses, policies, IP lists change |
| 6 | 55-ai-platform | 10, 30 | AI or app infrastructure changes |
| 7 | 60-governance | 10, 50 | masks, PII policies change |
| 8 | 70-observability | 10, 50 | platform views change |

## Documentation

| Document | Use it for |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the platform is designed and why |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | First-time setup, step by step, with verification |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-2 procedures: onboarding, new domain, sandboxes, offboarding, break-glass |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every config file and field |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Architecture decision records |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Expected first-run problems and fixes |

A separate learning guide (Claude Doc) teaches the concepts behind each stack,
with hands-on labs.

## Rules this repo enforces

1. Humans never write to prd data; only `sp-<prefix>-prd-deploy` does.
2. A prd catalog is unreachable from the dev workspace (workspace binding).
3. Nobody has direct storage access; Unity Catalog vends short-lived credentials.
4. No personal access tokens and no long-lived CI secrets (OIDC federation).
5. Every serverless DBU carries `piq_env` and `piq_domain` tags.
6. Changes to masking, tags and access require governance review (CODEOWNERS).
