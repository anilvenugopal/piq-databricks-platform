# Operations: day-2 procedures

Every procedure is a pull request. The "Apply" column lists which stacks to run,
in order, after merge.

| Procedure | Edit | Apply |
|---|---|---|
| Onboard a person | `config/personas.yaml` members (or via portal) | 20 |
| Give a person a dev sandbox | `config/sandbox_users.yaml` (or via portal) | 20, 30, 40 |
| Approve a prd experiment | `config/experiments.yaml` (Code Owner approval) | 20, 30, 40 |
| Offboard a person | remove from YAML; disable in Entra | 20, 40 |
| Add a domain | `config/domains.yaml` | 10, 20, 30, 40, 50, 55, 60 |
| Add a schema to every domain | `config/domains.yaml` `schemas` + `access_matrix.yaml` row | 40 |
| Change who can read a layer | `config/access_matrix.yaml` | 40 |
| Add a service principal | `config/service_principals.yaml` | 20, 30 |
| Add a PII type | `governed_tags.yaml` (value + mask), `sql/governance/masking_functions.sql` | 40, 60 |
| Change warehouses or policies | `config/workspace_objects.yaml` | 50 |
| Change budgets | `config/cost.yaml` | 30 |
| Allow an egress destination | `platform.yaml` `serverless_egress.allowed_domains` | 30 |
| Enable classic-compute internet | `platform.yaml` `nat_gateway: true` | 10 |

## Onboarding a person

Preferred: the access portal. The requester signs in with Entra, picks a persona,
and an issue labelled `access-request` is created. An admin adds `approved`; the
`provision-access` workflow opens a PR. Merge, apply 20 (and 30, 40 for a sandbox).

Manual equivalent:
```bash
python3 scripts/provision_access.py --upn jane@corp.com --persona data-analyst --sandbox --issue 12
python3 scripts/validate_config.py
git checkout -b access/jane && git commit -am "access: jane via #12" && git push
```

There is no Databricks user to create and no password: membership in Entra flows
into Databricks through automatic identity management, usually within minutes.

## Offboarding

1. Disable the account in Entra (HR process). Databricks access stops at the next
   token refresh.
2. `python3 scripts/provision_access.py --upn jane@corp.com --persona data-analyst --sandbox --remove`
3. Apply 20, then 40. **Applying 40 drops the user's sandbox schema and its
   tables.** Copy anything worth keeping first.

## Adding a domain

1. Add an entry under `domains:` in `config/domains.yaml`, and its key to the
   `piq_domain` values in `config/governed_tags.yaml`.
2. `python3 scripts/validate_config.py`
3. Apply 10 (storage container), 20 (36 → 48 groups), 30 (assignments, usage
   policy, budget), 40 (catalogs), 50 (warehouse ACLs pick up new groups),
   55 (app space), 60 (mask policies).
4. Create the domain's pipeline repo and add it to the deploy SPs'
   `github_subjects`, then apply 20 again.

## Production experiments

`config/experiments.yaml` entries need `approved_by`, `ticket` and `members`;
validation fails otherwise and CODEOWNERS requires platform-lead review. Set
`expires` and remove expired entries monthly: removing the entry and applying 40
drops `prd_sandbox.exp_<name>`.

## Break-glass access

Human account admins (`piq-account-admins`) are for emergencies only. When used:
record the reason in an issue, do the minimum by hand, then reproduce the change
in config and apply, so Terraform's desired state matches reality. Check
`prd_platform.audit.permission_changes` afterwards; anything not made by
`sp-piq-terraform` is drift until codified.

## Drift detection

Run the `plan` workflow on `main` weekly (or schedule it). A plan with changes when
nobody changed config means someone changed the platform by hand. Because grants
are authoritative, the next apply of stack 40 reverts manual grants: decide first
whether to codify or revert.

## Cost review (monthly)

```sql
-- in the prd workspace, as piq-platform-monitoring
SELECT piq_env, piq_domain, round(sum(list_cost_usd), 2) usd
FROM prd_platform.monitoring.cost_daily_by_env_domain
WHERE usage_date >= date_trunc('month', current_date())
GROUP BY ALL ORDER BY usd DESC;

SELECT * FROM prd_platform.monitoring.cost_untagged_usage
WHERE usage_date >= current_date() - INTERVAL 30 DAYS ORDER BY dbus DESC;
```

Untagged usage usually means a user ran serverless compute without being in a
usage-policy group, or a classic cluster bypassed the compute policies.

## Teardown (training account)

Reverse order: 70, 60, 55, 50, 40, 30, 20, 10, then bootstrap.
```bash
./scripts/tf.sh 40-unity-catalog destroy    # catalogs must be empty, or add force_destroy
```
Key Vaults are soft-deleted (7 days dev, 90 days prd with purge protection);
reusing the same names before then fails.
