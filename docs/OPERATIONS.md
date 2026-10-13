# Operations

Every procedure is a pull request. CODEOWNERS routes it to the right approver;
"Apply" lists the stacks to run, in order, after merge.

| Procedure | Edit | Approver | Apply |
|---|---|---|---|
| Publish a product | `config/products/<domain>.yaml` (new entry) | Producing domain | 20, 40 |
| Approve a consumer for a product | that product's `consumers` list | Producing domain | 20 |
| Deprecate a product | `status: deprecated`, then remove the entry | Producing domain | 40, then 20, 40 |
| Grant a SAR | `config/sars.yaml` members | Governance | 20 |
| Add a consumer domain | `config/consumers/<name>.yaml` | Platform | 10, 20, 30, 40, 50 |
| Add a person to a consumer group | none: the consumer lead adds them in Entra | Consumer lead | none |
| Onboard a domain team member | `config/personas.yaml` members | Platform | 20 |
| Give a person a dev sandbox | `config/sandbox_users.yaml` | Platform | 20, 30, 40 |
| Approve a prd experiment | `config/experiments.yaml` | Platform leads | 20, 30, 40 |
| Add a producer domain | `config/domains.yaml` + `config/products/<domain>.yaml` | Platform | 10, 20, 30, 40, 50, 55, 60 |
| Add a vault source | `domains.yaml` `vault.sources` + loader metadata in the vault repo | Platform, vault team | 40 |
| Enable anonymized data for a domain | `anon: true` in `domains.yaml` | Platform, governance | 10, 40 |
| Add a sensitive column type | `governed_tags.yaml` (tag value + mask), `sql/governance/masking_functions.sql`, `sars.yaml` | Governance | 40, 60 |
| Change compute | `workspace_objects.yaml` or the consumer's `warehouse` | Platform | 50 |
| Change budgets | `config/cost.yaml` | Platform | 30 |

## Publishing a product

1. In the domain repo, build the product's models and point them at schema
   `product_<name>` (see `templates/domain-bundle`). Nothing is copied: the
   models rebuild into the new schema.
2. In this repo, add the product to `config/products/<domain>.yaml` with a
   contract link and `status: published`.
3. Apply 20 (product group, nesting) and 40 (schema, grants, tags).
4. Tag sensitive columns (`pii`, `sensitive_metric`); masks apply automatically.

## Approving a consumer

The consumer (a domain or a consumer domain) opens an access request, or a
pull request adding itself to the product's `consumers` list. The producing
domain's owners approve it through CODEOWNERS. Apply 20. Who inside the
consumer domain gets access is the consumer lead's decision, made in Entra.

## Derived products

A domain that builds on other products is first approved as their consumer,
then reads their `product_*` schemas (never their private schemas) and
publishes its own product. Before changing a product's contract, check its
`consumers` list and `prd_platform.governance.lineage_recent` for dependants.

## Granting sensitive access

Governance adds the group reference to the SAR's members for the environment
(`consumer:exec_reporting:analyst`, `prd:profitability:producer`, ...). Apply 20.
Membership in the SAR unlocks its masks in every catalog, for every product,
including products published later.

## Anonymized production data

With `anon: true`, the domain gets `prd_{domain}_anon`, bound read-only to dev.
Its prd anonymization job (in the domain repo, reviewed by governance) writes
irreversibly anonymized data into `prd_{domain}_anon.data`; dev pipelines read
it like any source. ABAC masks do not count as anonymization.

## Onboarding and offboarding people

Domain teams: persona membership via the access portal (`persona` request) or
`config/personas.yaml`. Consumers: the consumer lead adds or removes people in
Entra directly. Offboarding: disable the Entra account; remove persona entries
and sandboxes by pull request (applying 40 drops the sandbox schema and its
tables, so copy anything worth keeping first).

## Break-glass access

Human account admins (`piq-mesh-admins`) are for emergencies. Record the
reason in an issue, do the minimum by hand, then codify the change and apply.
Anything in `prd_platform.audit.permission_changes` not made by
`sp-piq-terraform` is drift until codified; grants are authoritative and the
next apply of stack 40 reverts manual grants.

## Cost review (monthly)

```sql
SELECT piq_env, piq_domain, round(sum(list_cost_usd), 2) usd
FROM prd_platform.monitoring.cost_daily_by_env_domain
WHERE usage_date >= date_trunc('month', current_date())
GROUP BY ALL ORDER BY usd DESC;
```

Every warehouse carries `piq_domain`, and every other serverless DBU is tagged
by a usage policy; `monitoring.cost_untagged_usage` should be near zero.

## Teardown (training account)

Reverse order: 70, 60, 55, 50, 40, 30, 20, 10, then bootstrap. Catalogs must be
empty before stack 40 can drop them. Key Vaults are soft-deleted.
