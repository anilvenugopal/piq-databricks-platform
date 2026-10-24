# Operations

Every change is a pull request. CODEOWNERS routes it to the right approver. After the merge, someone
**deploys** it: runs one or more *targets* in the order shown in the "Deploy" column.

> **Status.** Nothing here has been applied to a real cloud account yet. The commands and file names
> are covered by tests that need no cloud access (`python3 tests/naming/run_tests.py`,
> `python3 tests/wrappers/run_tests.py`, `python3 tests/stacks/run_plan_tests.py`). Expect small
> surprises on the first real run, and see `docs/TROUBLESHOOTING.md`.

## Words used on this page

| Word | Meaning |
|---|---|
| **Stack** | A numbered folder under `stacks/` that Terraform applies, for example `40-unity-catalog`. |
| **Scope** | The slice of the platform one deploy owns: `shared` (account-wide things that span environments), `env` (one environment's infrastructure), `access` (people and approvals, stack 25 only), `domain:<name>` (one domain in one environment). |
| **Target** | A stack plus a scope plus, except for `shared`, an environment. Example: stack `40-unity-catalog`, environment `prd`, scope `domain:claims`. |
| **State** | Terraform's record of what it built. Each target has its own: `<stack>/shared.tfstate`, `<stack>/<env>/env.tfstate`, `<stack>/<env>/access.tfstate`, `<stack>/<env>/domain-<name>.tfstate`. Deploying claims in prd can only read and change the claims-in-prd record. |
| **Tier** | Each environment is `nonprod` or `prod` (`tier` in `config/platform.yaml`). Exactly one is `prod`. Rules depend on the tier, never on the name. |
| **Release tag** | A git tag `rel-YYYY.MM.DD.N` on a commit worth promoting. Cut with `scripts/release.py`. |
| **Promotion gate** | The check in `scripts/apply.py` that refuses a release for an environment unless it was already deployed successfully to every environment in that environment's `promotes_from`. |
| **Scope check** | The check in `scripts/plan.py` and `scripts/apply.py` that refuses a plan which would change anything the target does not own. |
| **Entitlement** | An access decision: who is in which group, which consumer may read which product. Kept in `config/entitlements/<env>/` and applied only by stack 25. It stands in for an identity-governance tool (SailPoint, Saviynt, PingID). |

## Which target does each procedure deploy?

`<stack> <scope>` below always means "in the environment you are changing". Do dev first, cut a release,
then repeat in prd (see "Deploy a domain change to dev, then prd").

| Procedure | Edit | Approver | Deploy, in order |
|---|---|---|---|
| Publish a product | `config/products/<domain>.yaml` (new entry) | Producing domain | `20 domain:<d>`, `30 domain:<d>`, `40 shared` (new tag value), `40 domain:<d>`, then `25 access` for approvals |
| Approve a consumer for a product | `config/entitlements/<env>/product_access.yaml` | Producing domain | `25 access` |
| Deprecate a product | `status: deprecated`, later remove the entry | Producing domain | `25 access` (remove approvals), `40 domain:<d>`, then `20 domain:<d>` |
| Grant a SAR (sensitive access role) | `config/entitlements/<env>/sars.yaml` | Governance | `25 access` |
| Add a consumer domain | `config/consumers/<name>.yaml` | Platform | `10`, `20`, `30`, `40`, `50`, `60` of `env` in the prod environment, then `25 access` |
| Add a person to a consumer group | none: the consumer lead adds them in Entra | Consumer lead | none |
| Give a person a persona | `config/entitlements/<env>/personas.yaml` | Platform (prd: platform and governance) | `25 access` |
| Make a person a domain database admin | `config/entitlements/<env>/admins.yaml` | Platform | `25 access` |
| Give a person a nonprod sandbox | `config/entitlements/<env>/sandboxes.yaml` | Platform | `25 access`, `30 env`, `40 env` |
| Approve a prod experiment | `config/entitlements/<prod env>/experiments.yaml` | Platform leads | `25 access`, `30 env`, `40 env` |
| Add a producer domain | `config/domains.yaml`, `config/products/<domain>.yaml` | Platform | see "Add a domain" (it re-runs `40 shared`) |
| Add a schema, role or persona to one domain | `config/domain_shape/<domain>.yaml` and `config/domain_access/<domain>.yaml` | Domain team, then platform and governance | see "Add a schema, role or persona" |
| Add a vault source | `config/domains.yaml` `vault.sources` + loader metadata in the vault repo | Platform, vault team | `40 shared` (new tag value), then `40 env` |
| Enable anonymized data for a domain | `anon: true` in `config/domains.yaml` | Platform, governance | `10 env`, `30 domain:<d>`, `40 domain:<d>`, all in the prod environment |
| Add a sensitive column type | `config/governed_tags.yaml` (tag value + mask), `sql/governance/masking_functions.sql`, `config/sars.yaml` | Governance | `40 shared`, then `60 env`, then `60` of every domain |
| Change a rule that applies to every domain | `config/access_matrix.yaml` and similar | Platform and governance | see "Roll out a shared-rule change" |
| Change compute | `config/workspace_objects.yaml` or the consumer's `warehouse` | Platform | `50 env`, `50` of every domain |
| Change budgets | `config/cost.yaml` | Platform | `30 env`, `30` of every domain |
| Add an environment | `config/platform.yaml` and others | Platform | see "Add an environment" |

## Deploy one target

Two ways. They run the same scripts.

| | On your machine | In the pipeline |
|---|---|---|
| Needs | `az login`, `pip install -r requirements.txt`, Terraform | GitHub environments and variables from RUNBOOK Phase 2 |
| Plan only | `python3 scripts/plan.py 40-unity-catalog --env dev --scope domain:claims` | start **deploy** and read the plan in the run summary before approving |
| Plan and apply | `python3 scripts/apply.py 40-unity-catalog --env dev --scope domain:claims` | `gh workflow run deploy.yml -f stack=40-unity-catalog -f environment=dev -f scope=domain:claims -f ref=main` |
| Approval | you type `y` at the prompt | the **apply** job waits for the reviewers of the GitHub environment (required for the prod environment) |
| What gets applied | the plan you just read | the saved plan from the plan job: the approver reads the exact plan that runs |

Rules both ways:

- `--env` is required for every scope except `shared`, which takes no environment. Allowed scopes per stack are
  in `stacks/<stack>/stack.yaml`.
- `scripts/apply.py --yes` works **only** together with `--plan FILE`. A pipeline applies a plan a person
  already read, never a fresh one.
- Before applying, the **scope check** reads the plan and refuses it if it changes another environment's or
  another scope's resources (exit code 4).
- After applying, the stack's checks run (`stacks/<stack>/checks.py`) and a **deploy record** is written to the
  `deployments` container of the state storage account. `--no-record` skips the record for local experiments;
  `PIQ_DEPLOY_STORE=local` keeps records in `audit/deploys/` instead.
- An empty plan still records the release as deployed. A release that does not touch claims must still be
  promotable for claims.

Exit codes of `apply.py`: `0` done, `1` failed (target invalid, plan, apply or checks), `2` declined at the prompt or
`--yes` without `--plan`, `4` scope check refused, `5` promotion gate refused.

### Order matters

The first environment is deployed in this order. A step marked "once" is a shared-scope step: it covers every
environment, so later environments do not repeat it (except where noted).

```
10 env
20 shared (first, once)  ->  20 env  ->  20 domain:<each>  ->  25 access
   (RUNBOOK Phase 4, once, by hand: claim the account, set piq-metastore-admins as metastore admin,
    make every Terraform identity a Databricks account admin)
30 shared (once)  ->  30 env  ->  30 domain:<each>
40 shared (once)  ->  40 env  ->  40 domain:<each>
        ^ needs stack 30 finished for EVERY environment (see below); run again when an environment is added
50 env  ->  55 env  ->  60 env           then   50, 55, 60 domain:<each>
70 env                                   (the prod environment only)
```

Why this order:

- **Groups before anything that names them.** 20 comes before 30, 40, 50 and 60. Stack 30 also resolves the groups into
  the Databricks account, which Unity Catalog grants need.
- **`20 shared` first.** The shared groups (for example `piq-metastore-admins`, `piq-mesh-governance`) must exist before
  the environments link to them.
- **`20 env` before `20 domain`.** The persona groups are made by the env scope; the links that put a persona into a
  domain's roles are made by the domain scope, so the personas must already exist.
- **Who owns a group-in-group link.** A link belongs to the scope of the group being joined (the *parent*). The one
  exception is a link into a **shared** group: it belongs to the scope of the group that joins, so that the shared scope
  never has to wait for an environment. A group owned by another scope is found by its display name, which is why the
  other scope must have run first.
- **`40 shared` waits for 30 in every environment.** It creates the governed tags, and the rules about who may assign
  them name the groups of every environment (and of every domain). Those groups must exist (20) and be resolved into the
  account (30) in **every** environment first. Run `40 shared` again when an environment or a domain is added, or when a
  tag value changes (a new product, domain or vault source).
- **`40 env` before `40 domain`**: it creates the storage credential every domain catalog in that environment uses.
  **`60 env` before `60 domain`**: it creates the masking functions the mask policies call.

## Deploy a domain change to dev, then prd

Worked example: the claims team adds a product `claim_triangle`.

1. **Change and merge.** Edit `config/products/claims.yaml`. The pull request plans every target of the first
   nonprod environment and comments what would change (`plan.yml`).
2. **See what changed.** Plans are read-only:
   ```bash
   python3 scripts/plan_all.py --env dev --stack 40-unity-catalog --scope domain:claims
   ```
   `plan_all.py` takes `--stack` and `--scope` more than once, and `--include-shared` to add the shared scope. Exit code
   `2` means at least one target has changes. Without `--stack` it plans every target of the environment, which is slow.
3. **Deploy to dev**, in stack order, for the scope that changed (see "Publish a product"):
   ```bash
   python3 scripts/apply.py 20-identity     --env dev --scope domain:claims
   python3 scripts/apply.py 30-account      --env dev --scope domain:claims
   python3 scripts/apply.py 40-unity-catalog --scope shared      # a new product adds a value to a governed tag
   python3 scripts/apply.py 40-unity-catalog --env dev --scope domain:claims
   python3 scripts/apply.py 25-access       --env dev --scope access
   ```
   `40 shared` has no environment and covers every environment at once, so you run it once; in prd it will show no
   changes. Dev accepts any commit. The deploy record says `sha:<commit>`. Deploy as often as you like.
4. **Cut a release** when dev looks right: see "Cut a release".
5. **Promote to prd.** Prd only accepts a release tag that already passed dev for the **same stack and scope**:
   ```bash
   git checkout rel-2026.10.23.1
   python3 scripts/apply.py 20-identity     --env prd --scope domain:claims --release rel-2026.10.23.1
   python3 scripts/apply.py 30-account      --env prd --scope domain:claims --release rel-2026.10.23.1
   python3 scripts/apply.py 40-unity-catalog --env prd --scope domain:claims --release rel-2026.10.23.1
   python3 scripts/apply.py 25-access       --env prd --scope access          --release rel-2026.10.23.1
   ```
   (The shared scope has no environment, so the promotion gate does not apply to it.)
   In the pipeline, pass the tag as `ref`: `gh workflow run deploy.yml -f stack=40-unity-catalog -f environment=prd -f scope=domain:claims -f ref=rel-2026.10.23.1`.

Other domains are untouched: each target has its own state, and the scope check backs that up.

## Cut a release

```bash
python3 scripts/release.py            # tags HEAD rel-YYYY.MM.DD.N; needs a clean tree and a valid config
python3 scripts/release.py --push     # ...and pushes the tag
python3 scripts/release.py --list     # all releases
```

Or run the **release** workflow (`gh workflow run release.yml`, optional `-f ref=<sha>`): it runs config validation,
`terraform fmt`, the naming, wrapper and mocked-plan tests, then tags and pushes. A release is a frozen snapshot of the
whole repo; deploying it to a domain applies only that domain's part of it.

## See what is deployed where

```bash
python3 scripts/status.py                       # every target
python3 scripts/status.py --env prd --stack 40-unity-catalog
```

It prints the latest successful deploy of each target, from the deploy records. `-` means never deployed.

## Environments are a graph

`promotes_from` in `config/platform.yaml` says where a release must have been deployed first. Any number of
environments may be listed:

```yaml
dev:  { tier: nonprod, promotes_from: [] }          # accepts any commit
qa:   { tier: nonprod, promotes_from: [dev] }
prd:  { tier: prod,    promotes_from: [qa], allow_hotfix: true }
```

With two dev environments, `qa` can say `promotes_from: [dev1, dev2]`: it then needs the release to have passed in
**both**. Cycles are rejected by `scripts/validate_config.py`.

## Hotfix

A hotfix is a release allowed to skip the gate, where the environment says so (`allow_hotfix: true`) and a named
person approves it.

```bash
python3 scripts/status.py --env prd                       # which release is in prd now
git switch -c hotfix/claims-grant rel-2026.10.20.2        # start from what prd runs
# ...commit the fix...
python3 scripts/release.py --push                         # a hotfix is still a rel-... tag
python3 scripts/apply.py 40-unity-catalog --env prd --scope domain:claims \
  --release rel-2026.10.25.1 --hotfix --approver "Jane Smith"
```

In the pipeline: `-f ref=rel-2026.10.25.1 -f hotfix=true -f approver="Jane Smith"`; the GitHub environment reviewers
still approve. Afterwards:

1. **Replay** the release through the environments it skipped (deploy it to dev the normal way).
2. **Merge** the fix to `main`.

## Roll out a shared-rule change

A *shared rule* is config that every domain reads: `config/access_matrix.yaml`, `config/personas.yaml`,
`config/workspace_objects.yaml`, `modules/naming/`. Merging it changes nothing by itself. Each domain picks it up the
next time that domain is deployed, along with whatever else it was deploying. To avoid surprises, roll it out as its own
step.

Example: `config/access_matrix.yaml` changes analyst access on `reporting` from `RW` to `R`.

1. **Merge**, then see who is affected: `python3 scripts/plan_all.py --env dev --stack 40-unity-catalog`.
2. **Deploy to dev**, one domain at a time:
   ```bash
   for d in claims policy_financial profitability; do
     python3 scripts/apply.py 40-unity-catalog --env dev --scope domain:$d
   done
   ```
3. **Cut a release**, then repeat the loop in prd with `--release`.

If a team must ship its own change before the rollout, deploy from an **earlier release tag** that does not contain the
rule change: `git checkout rel-<before>` and pass `--release rel-<before>`. Or branch from that tag, cherry-pick only the
team's commit, cut a release, and deploy that.

## Add a domain

Example: a new domain `marketing`.

1. Edit `config/domains.yaml` (`repo`, `description`, `owner`, `anon`, `lakebase`, `app_space`) and add
   `config/products/marketing.yaml`. Add CODEOWNERS lines for the new files.
2. Run `python3 scripts/validate_config.py` and `python3 tests/naming/run_tests.py`.
3. Deploy in this order. Because `40 shared` names the groups of **every** environment, the identity steps run in
   every environment before it; the rest can go dev first:
   ```
   in EVERY environment:   10 env                # the domain's storage container
                           20 domain:marketing   # its groups and deploy service principal
                           30 domain:marketing   # resolves them into the Databricks account, usage policy, budget
                           30 env                # resolves the new groups that the vault grants name
   once:                   40 shared             # new domain = new tag values and new tag-assigner groups
   per environment:        40 env                # vault grants for the new domain
                           40 domain:marketing   # catalog, schemas, grants
                           50 domain:marketing
                           55 domain:marketing
                           60 domain:marketing   # needs 60 env to have run already
                           25 access             # approvals and people
   ```
   Dev first, with one release: deploy the first block in dev, cut a release, deploy the first block in prd with that
   release, run `40 shared`, then the last block in dev and, with the same release, in prd.
4. In the domain's own repo, create GitHub environments named exactly after your environments (`dev`, `prd`) and set
   the deployment identity from the `service_principals` output of `20 domain:marketing`. The identity trusts
   `repo:<org>/<repo>:environment:<env>` only.

## Add a schema, role or persona to one domain

The standard schemas, roles and personas stay the default for everyone (`config/domains.yaml`,
`config/access_matrix.yaml`, `config/personas.yaml`). A domain adds its own in two files, because two groups decide:

| File | Who approves | What it holds |
|---|---|---|
| `config/domain_shape/<domain>.yaml` | The domain team | Names only: extra schemas (or standard ones to `remove`), extra roles, extra personas |
| `config/domain_access/<domain>.yaml` | Platform and governance | What roles may do on schemas, warehouse `CAN_USE`/`CAN_MANAGE`, and each domain persona's access per environment |

Example: claims adds a schema `adjuster_notes` and a role `adjuster`.

```yaml
# config/domain_shape/claims.yaml
schemas:
  add:
    adjuster_notes: { layer: INFO_MART, comment: "Free-text adjuster notes" }
roles:
  adjuster: { description: "Claims adjusters" }
```
```yaml
# config/domain_access/claims.yaml
schemas:
  adjuster_notes: { producer: RWC, adjuster: R }
  reporting:      { analyst: R }                  # tighter than the standard, for claims only
  info_mart:      { analyst: { nonprod: RW, prod: R } }   # a bundle may differ by tier
```

Limits (checked by the validator and the naming module): a bundle can never exceed `override_ceiling` in
`access_matrix.yaml`; the `admin` schema cannot be changed or removed; a domain persona can only reference its own
domain's roles; names may not collide with standard schemas, standard or reserved roles, or global personas; schema
names may not start with `product_`. A role marked `service_principal_only: true` cannot hold humans in the prod
environment. Wildcards such as `dev:*:analyst` match every domain that has that role.

Deploy per environment: `20 domain:<d>` (new role or persona groups), `30 domain:<d>`, `40 domain:<d>` (schemas and
grants), `50 domain:<d>` (warehouse access), `25 access` (people). Schema names carry no environment, so a new schema
appears in dev first and reaches prd when you promote a release.

## Add an environment

Example: add `qa` between dev and prd. No code changes are needed: the code only reads config. These are the places to
edit, found by searching the repo for environment names.

1. **`config/platform.yaml`**: a new entry under `environments:` with `tier: nonprod`, `promotes_from`, `allow_hotfix`,
   and a full `network` block with CIDRs that do not overlap the others, `storage_replication`, `ip_access_list` and
   `serverless_egress`. The name must be 2 to 8 lowercase letters or digits. Then change prd's `promotes_from` to `[qa]`.
2. **`config/personas.yaml`**: every persona needs an `access.qa` list (use `[]` for none), or validation fails with
   "access.qa is missing". In `platform_groups`, add `qa: USER` (or `ADMIN`) to the `workspaces` of groups that should
   reach the qa workspace: `mesh-admins`, `metastore-admins`, `mesh-governance`, `platform-monitoring`, and
   `sandbox-users` if qa gets sandboxes. `qa-workspace-admins` is generated for you.
3. **`config/cost.yaml`**: add `qa` to `environment_monthly_usd` (and to the other budget lists you use). Optional: an environment with no entry simply gets no environment budget.
   `domain_monthly_usd`, `vault_monthly_usd` are optional (no entry means no budget).
4. **`config/governed_tags.yaml`**: nothing to do. The `piq_env` tag values are generated from the environments in `platform.yaml`; deploy `40 shared` again (step 9) so the new value is created.
5. **`config/service_principals.yaml`**: add `qa: USER` to `workspaces` of any extra principal that must reach qa.
6. **`config/entitlements/qa/`**: copy the files from `dev` and edit (optional; a missing file means "nothing").
7. **Identities.** Re-run `bootstrap/` (RUNBOOK Phase 2). It creates `rg-piq-qa`, `sp-piq-terraform-qa` and the OIDC
   trust for the GitHub environments `qa` and `qa-plan`. Add `sp-piq-terraform-qa` as a Databricks account admin
   (`env_terraform_sps` output).
8. **GitHub.** Create environments `qa` and `qa-plan`; set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID` on both from `github_variables.by_environment.qa`. Add reviewers to `qa` if you want them.
9. **Deploy**, in this order:
   1. `20 shared` again: it adds the new identity to `piq-metastore-admins`.
   2. For the new environment: `10 env`, `20 env`, `20 domain:<each>`, `25 access`, `30 env`, `30 domain:<each>`.
   3. `40 shared` again, once step 2 is finished (the `piq_env` tag gained a value, and the tag-assigner rules now name
      the new environment's groups, which stack 30 must have resolved first).
   4. `40 env`, `40 domain:<each>`, then `50`, `55` and `60` (env, then domains) for the new environment.

Two behaviours to know: the shared scope of stack 40 calls through the workspace of the **first nonprod environment in
alphabetical order**, and `plan.yml` plans against that same environment. Exactly one environment may be `prod`;
consumer domains, anonymized-data writers and experiments live in it.

Only comments and examples in `scripts/run_sql.py` and `util/naming_eval.py` still mention `dev` or `prd`.

## Give or remove access to a person

People and approvals are entitlements in `config/entitlements/<env>/`, one folder per environment, so a person can be
a data engineer in dev and only a data analyst in prd.

```bash
python3 scripts/provision_access.py persona --env prd --upn jane@premiumiq.com --name data-analyst
python3 scripts/provision_access.py persona --env dev --upn jane@premiumiq.com --name data-engineer
python3 scripts/provision_access.py persona --env dev --upn jane@premiumiq.com --name claims/adjuster-analyst --remove
```

Request types are `persona`, `sandbox`, `product`, `sar` and `admin`; all need `--env`. A domain persona is written
`<domain>/<persona>`. The script preserves comments; you can also edit the YAML by hand. Open a pull request (the
access-request workflow `provision-access.yml` does this for approved issues), then deploy:

```bash
python3 scripts/apply.py 25-access --env prd --scope access
```

The person must already exist in Entra. Offboarding: disable the Entra account, remove the lines (`--remove`), deploy
`25 access`. Removing a sandbox user and deploying `40 env` drops their sandbox schema and its tables, so copy anything
worth keeping first.

**When an identity-governance tool takes over.** Delete `config/entitlements/`, `stacks/25-access/`,
`scripts/provision_access.py` and `.github/workflows/provision-access.yml`, and remove `25-access` from the stack list
in `deploy.yml`. The tool then manages membership of the same group names, which are the contract:

| Group | Name |
|---|---|
| Persona | `piq-<env>-persona-<name>`, domain persona `piq-<env>-persona-<domain>-<name>` |
| Domain role | `piq-<env>-<domain>-<role>` (with hyphens), database admins `piq-<env>-<domain>-dbadmin` |
| Product readers | `piq-<env>-product-<product>` |
| SAR | `piq-<env>-sar-<sar>` |
| Consumer | `piq-<prod env>-<consumer>-<role>` (their lead already manages membership) |
| Sandboxes, experiments | `piq-sandbox-users`, `piq-<prod env>-experimenters` |

Sandbox schemas and experiment schemas are created by `40 env` from the same files, so keep those two lists, or move
them to self-service, when you delete the folder.

## Anonymized production data

With `anon: true`, the domain gets `<prod env>_<domain>_anon`, bound read-only to every nonprod environment. Its
anonymization job (in the domain repo, reviewed by governance) writes irreversibly anonymized data into
`<prod env>_<domain>_anon.data`; nonprod pipelines read it like any source. ABAC masks do not count as anonymization.

## Fix drift on demand

*Drift* is a difference between what the repo says and what is really there, usually someone changing something by hand.

1. See it: `python3 scripts/plan.py 40-unity-catalog --env prd --scope domain:claims`. A manual change shows up as a
   difference the plan would revert.
2. Fix it: `python3 scripts/apply.py 40-unity-catalog --env prd --scope domain:claims --release <the release in prd>`
   (the pipeline does the same through `deploy.yml`). Terraform reverts what it manages. Grants are authoritative, so a
   hand-made grant on a managed object is removed. Something created by hand outside Terraform is left alone.
3. Find it early: the **drift** workflow runs nightly, plan only, for every environment (`scripts/plan_all.py`). A
   target with changes fails the job. It never applies anything. After a merge that nobody has deployed yet it also
   reports changes: that is expected until the deploy.

## Publishing a product

1. In the domain repo, build the product's models and point them at schema `product_<name>` (see
   `templates/domain-bundle`). Nothing is copied: the models rebuild into the new schema.
2. In this repo, add the product to `config/products/<domain>.yaml` with a contract link and `status: published`.
3. Deploy `20 domain:<domain>` (product group), `30 domain:<domain>` (account resolution), `40 shared` (the product name
   is a new value of the `piq_product` tag), `40 domain:<domain>` (schema, grants, tags), then `25 access` for approvals.
4. Tag sensitive columns (`pii`, `sensitive_metric`); masks apply automatically.

## Approving a consumer

The consumer (a domain or a consumer domain) opens an access request, or a pull request adding itself to the product in
`config/entitlements/<env>/product_access.yaml`. The producing domain's owners approve it through CODEOWNERS. Deploy
`25 access`. A consumer domain (from `config/consumers/`) can only be approved in the prod environment. Who inside the
consumer domain gets access is the consumer lead's decision, made in Entra.

## Derived products

A domain that builds on other products is first approved as their consumer, then reads their `product_*` schemas (never
their private schemas) and publishes its own product. Before changing a product's contract, check the product's entries
in `config/entitlements/*/product_access.yaml` and `<prod env>_platform.governance.lineage_recent` for dependants.

## Granting sensitive access

Governance adds the group reference under the SAR's name in `config/entitlements/<env>/sars.yaml`
(`consumer:exec_reporting:analyst`, `prd:profitability:producer`, ...) and deploys `25 access`. Membership in the SAR
unlocks its masks in every catalog of that environment, for every product, including products published later.

## Break-glass access

Human account admins (`piq-mesh-admins`) are for emergencies. Record the reason in an issue, do the minimum by hand,
then codify the change and deploy it. Anything in `<prod env>_platform.audit.permission_changes` not made by a
Terraform identity (`sp-piq-terraform` or `sp-piq-terraform-<env>`) is drift until codified; grants are authoritative and
the next deploy of that target reverts manual grants.

## Cost review (monthly)

```sql
SELECT piq_env, piq_domain, round(sum(list_cost_usd), 2) usd
FROM prd_platform.monitoring.cost_daily_by_env_domain
WHERE usage_date >= date_trunc('month', current_date())
GROUP BY ALL ORDER BY usd DESC;
```

Replace `prd_platform` with `<prod env>_platform` if your prod environment has another name. Every warehouse carries
`piq_domain`, and every other serverless DBU is tagged by a usage policy; `monitoring.cost_untagged_usage` should be near
zero.

## Teardown (training account)

Reverse of the deploy order, one target at a time:

```
per environment:  70 env;  60, 55, 50 domains then env;  40 domains, 40 env
then:             40 shared
per environment:  30 domains, 30 env;  25 access;  20 domains, 20 env;  10 env
then:             30 shared, 20 shared, then bootstrap
```

Each step: `./scripts/tf.sh <stack> --env <env> --scope <scope> init`, then the same command with `destroy`. Catalogs must
be empty before stack 40 can drop them. Key Vaults are soft-deleted. Domains go before `env` because their catalogs use the
environment's storage credential. The one-off migration from the old single-state layout is in RUNBOOK.
