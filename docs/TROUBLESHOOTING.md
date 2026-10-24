# Troubleshooting

This repo has not been applied to a live account yet. These are the problems most likely on a first run, with the fix
for each. Entries marked **(cloud, unverified)** describe how the cloud usually behaves; they have not been seen here.
Entries about the scripts, config validation and tests are covered by the test suites.

How to read a target: stack + environment + scope, for example `40-unity-catalog`, `prd`, `domain:claims`. Words such as
*scope*, *tier*, *promotion gate* are explained at the top of `docs/OPERATIONS.md`.

## First-run problems

| Symptom | Likely cause | Fix |
|---|---|---|
| Bootstrap: `Authorization_RequestDenied` on app role assignment | You are not Global Admin / Privileged Role Admin | Run bootstrap as a Global Administrator |
| Bootstrap: a resource group "already exists ... needs to be imported" **(cloud, unverified)** | A resource group `rg-<prefix>-<env>` is still there from the old layout, where stack 10 created it | Finish the teardown of the old stack 10 first, or `terraform import` the group into bootstrap |
| 10-foundation: lookup of resource group `rg-<prefix>-<env>` fails | Bootstrap has not been run for that environment, so the group does not exist | Run `bootstrap/` (it creates one resource group per environment in `platform.yaml`) |
| 10-foundation: storage account name taken | `unique_suffix` collides globally | Change `unique_suffix` in `platform.yaml` |
| 10-foundation: Key Vault name in use | Soft-deleted vault from a teardown | `az keyvault purge --name <name>` (dev) or wait out retention, or change `unique_suffix` |
| 20-identity or 30-account: group, user or service principal "not found" (an Entra lookup by name) | The earlier stack has not created it yet, or the UPN is wrong | Deploy `20-identity` for the scope that owns the group first; fix the UPN. Stacks 25 and 30 find groups by display name |
| 30-account: `external-groups ... not onboarded onto AIM` | Automatic identity management off | Account console → Settings → enable it (RUNBOOK Phase 4) |
| 30-account: 403 on any call | The Terraform identity is not account admin | RUNBOOK Phase 4: `sp-piq-terraform` **and every** `sp-piq-terraform-<env>` must be a Databricks account admin |
| 30-account: Entra lookup of a user fails | A UPN in `entitlements/<env>/sandboxes.yaml` or `experiments.yaml` is not in Entra | Fix the UPN |
| 40: `PERMISSION_DENIED: CREATE STORAGE CREDENTIAL` | Metastore admin not set to `piq-metastore-admins`, or the environment's identity is not in it | RUNBOOK Phase 4; `20 shared` adds every Terraform identity to that group; wait a few minutes for group sync |
| 40: workspace binding already exists | ISOLATED catalogs auto-bind their creating workspace | Remove the `databricks_workspace_binding` resource for same-workspace bindings, or `terraform import` it |
| 40: tag assignment fails "value not allowed" | Value missing from `governed_tags.yaml`; for `piq_env`, `piq_domain`, `piq_product` and similar the values are generated, so a new environment or domain has not reached the tag taxonomy yet | Deploy `40 shared` (it creates the new values), then retry |
| 40: grant to a group fails "principal does not exist" | Group not yet resolved into the account | Deploy `30-account` for the same scope first; it resolves groups through AIM. For `40 shared` (tag assigners), stack 30 must have finished for **every** environment |
| 50: `databricks_system_schema` error "already enabled" | Schema enabled by default in your account | Remove it from `system_schemas` in `stacks/50-workspace/main.tf` |
| 50: warehouse creation slow | Normal on first serverless warehouse | Wait; timeout is 20 minutes by default |
| 60: `run_sql.py` ModuleNotFoundError | Runner lacks the SDK | `pip install -r requirements.txt` |
| Classic cluster stuck "Pending" | No outbound internet without NAT | Set `nat_gateway: true` for that environment, deploy `10 env`, or use serverless |
| CI blocked after enabling IP lists | GitHub-hosted runner IPs not allowed | Empty `ip_access_list`, or use self-hosted runners in an allowed range |
| Masking does not apply | Column tagged on the table, not the column; or user is in an exempt group | Tag the column itself; check group nesting |
| New group exists in Entra but is missing in Databricks, or a grant fails right after a deploy | AIM sync delay, usually under a minute | Wait a minute and re-run the failed target |

## Deploy pipeline and scripts

| Symptom | Likely cause | Fix |
|---|---|---|
| `deploy.yml` login fails with `AADSTS70021: No matching federated identity record` **(cloud, unverified)** | The GitHub environment name does not exactly match the trust created by bootstrap: `<env>`, `<env>-plan`, `shared`, `shared-plan` | Create GitHub environments with those exact names, with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` set on each (bootstrap output `github_variables`) |
| `ERROR: --yes needs --plan. A pipeline applies a plan that a person already reviewed, never a new one.` (exit 2) | `scripts/apply.py --yes` without `--plan FILE` | Run `scripts/plan.py ... --out FILE`, read it, then `scripts/apply.py ... --plan FILE --yes`; or drop `--yes` and answer the prompt |
| `ERROR: stack X does not support scope 'k' (supports: ...)` | The stack does not have that scope; see `stacks/<stack>/stack.yaml` | Use a supported scope. Example: `10-foundation` is `env` only |
| `ERROR: scope 'shared' takes no environment` / `scope 'domain:claims' needs --env` / `unknown environment 'x' (known: ...)` / `unknown domain 'x' (known: ...)` | Wrong combination of `--env` and `--scope` | Shared has no environment; every other scope needs one from `config/platform.yaml`; domain names are keys of `config/domains.yaml` |
| `scope must be shared, env, access or domain:<name> (got 'x')` | Malformed scope | Use `shared`, `env`, `access` or `domain:<name>` |
| `70-observability only runs in the prod environment (prd)` | It builds views over account-wide system tables in the prod environment | Run it with `--env <the prod environment> --scope env` |
| `pass --scope (shared \| env \| access \| domain:<name>)` from `tf.sh` | `scripts/tf.sh` always needs a scope | `./scripts/tf.sh <stack> --scope <scope> [--env <env>] <terraform args>` |
| `Backend configuration changed`, or a plan wants to create everything, after switching targets | `.terraform` still points at the previous target's state key | Always initialise through the wrapper: `./scripts/tf.sh <stack> --env <env> --scope <scope> init` (it uses `-reconfigure`). `plan.py`, `apply.py` and `check.py` do this for you; plain `terraform` in a stack folder does not |
| Applying a saved plan fails or says it is stale | The plan file belongs to another target or older config | Plan files are per target: `stacks/<stack>/<env>-<scope>.tfplan`. Plan again for the target you are applying |
| Checks fail right after apply with `RETRY` messages | AIM sync or API delay | Wait; the runner retries 5 times. Re-run `python3 scripts/check.py <stack> --env <env> --scope <scope>` later |
| `evaluate()` / `util.naming_eval` cannot find `config/platform.yaml` | The config directory does not exist at the path you gave (relative paths are now resolved for you) | Pass the real config directory |

## Promotion gate, releases and hotfixes

`scripts/apply.py` prints these. Exit code `1` is a problem with the request; exit code `5` is the gate itself.

| Message | Cause | Fix |
|---|---|---|
| `PROMOTION GATE REFUSED rel-... for <target>:` then `rel-... has not been deployed successfully to dev for 40-unity-catalog [domain:claims]` | The release has no passing record in that environment **for the same stack and scope**. Deploying claims to dev says nothing about policy_financial, or about stack 30 | Deploy the release to the listed environment for that exact stack and scope first. `python3 scripts/status.py --env dev` shows what is there |
| The same message, but you did deploy it | (a) the dev deploy ended `FAIL` (checks failed): a failed deploy does not count; (b) the record store cannot be read: with no `az login`, or without blob access to the state storage account, `apply.py` stops with "could not read deploy records" instead of guessing; (c) you deployed a different tag | Fix the failing checks and deploy again; run `az login` and confirm Storage Blob Data access; check the tag name. `PIQ_DEPLOY_STORE=local` reads `audit/deploys/` instead |
| `environment prd only accepts a release tag (rel-YYYY.MM.DD.N), not sha:...` | Environments with `promotes_from` refuse a plain commit | `python3 scripts/release.py`, then deploy that tag |
| `environment prd only accepts a release tag; HEAD has none (cut one with scripts/release.py)` (exit 1) | HEAD is not on a release tag | `git checkout rel-...` and pass `--release rel-...` |
| `HEAD is not rel-...: check out the tag (git checkout rel-...) so the code that runs is the code that was released` | `--release` names a tag that is not at HEAD | `git checkout <tag>` |
| `the working tree has uncommitted changes; deploy a clean checkout of the release` | Local edits while deploying a release | Commit, stash or discard them |
| `--release must look like rel-YYYY.MM.DD.N (got ...)` | Wrong tag format | Use the tag printed by `release.py --list` |
| `a hotfix deploy needs --approver <name>` | `--hotfix` without an approver | Add `--approver "Name"` (pipeline: the `approver` input) |
| `environment dev does not allow hotfix deploys (allow_hotfix: false)` | The environment has no hotfix path | Hotfixes only go where `allow_hotfix: true` (prd by default). Deploy to dev the normal way |
| `ERROR: the working tree has uncommitted changes; commit them first.` or `ERROR: config does not validate; fix it before releasing.` from `scripts/release.py` | The script refuses a dirty tree or an invalid config | Commit; run `python3 scripts/validate_config.py` and fix what it lists |

## Scope check and "why does this plan touch that?"

| Symptom | Cause | Fix |
|---|---|---|
| `SCOPE CHECK FAILED: the plan changes things this target does not own:` then `<resource address>  belongs to prd/domain:profitability, this run owns prd/domain:claims` (exit 4) | The plan would change a resource owned by another environment or scope. Normally impossible, because each target has its own state; it means a stack was split wrongly, or a resource key is built from the wrong item | **Do not apply.** Find the owner: <br>`python3 - <<'PY'`<br>`from pathlib import Path`<br>`from util.naming_eval import evaluate`<br>`ok, n = evaluate(Path("config").resolve())`<br>`print(n["schemas"]["domain:prd:claims/product_loss"]["sid"])`<br>`PY`<br>then report it as a bug in the stack. `tests/naming/run_tests.py` (partition test) and `tests/wrappers/run_tests.py` cover this check |
| `note: could not attribute <address>` after a plan | A changed resource has an instance key the naming module does not know (a derived key). It is a note, not a failure | Read that resource in the plan; if it is yours, ignore the note |
| A domain's plan contains a change you did not make (for example analysts lose `MODIFY` on `reporting`) | A **shared rule** (for example `config/access_matrix.yaml`) was merged earlier and has not reached this domain yet. This deploy picks it up along with your change. No other domain is touched | Read the plan. Either accept it, or deploy from an earlier release tag that predates the rule, or roll the rule out to every domain first (OPERATIONS: "Roll out a shared-rule change") |
| A plan in prd shows changes though nothing was merged | Drift: someone changed something by hand, or a merged change was never deployed to prd | `python3 scripts/plan.py ...` and read it. Apply to revert (OPERATIONS: "Fix drift on demand") |
| `drift.yml` fails every night for one target | That target has changes: drift, or merged changes not yet deployed | Open the job summary (a table per environment), plan that target, deploy or investigate |

## Access, entitlements and shared scopes

| Symptom | Cause | Fix |
|---|---|---|
| A person is not in the group after deploying `20-identity` | People are no longer added by stack 20. Memberships and approvals are stack 25 (`config/entitlements/<env>/`) | `python3 scripts/apply.py 25-access --env <env> --scope access` |
| Validator: `persona X: use access.<env>; members moved to config/entitlements/<env>/personas.yaml` | Old format: `members` or `member_of` in `config/personas.yaml` | Put the access under `access.<env>`; move people to `config/entitlements/<env>/personas.yaml` |
| Validator: `domain 'x': admins moved to config/entitlements/<env>/admins.yaml` / `product 'x': consumers moved to config/entitlements/<env>/product_access.yaml` / `SAR 'x': members moved to config/entitlements/<env>/sars.yaml` | Old locations | Move the data into `config/entitlements/<env>/` |
| 25-access: a group is "not found" | The group is owned by a scope that has not been deployed (a domain's groups come from `20 domain:<d>`; persona groups from `20 env`; shared groups from `20 shared`) | Deploy the missing `20-identity` target first: `shared`, then `env`, then the domain |
| `Persona assignments that resolve to no group: <env>: <upn> -> persona:<env>:<name>` or validator `has unknown persona 'x'` | A name in `entitlements/<env>/personas.yaml` is not a persona; a domain persona is written `<domain>/<persona>` | Fix the name. Global personas are in `config/personas.yaml`; domain personas in `config/domain_shape/<domain>.yaml` |
| `Entitlements in the wrong environment tier: <env>: sandboxes belong in a nonprod environment` (or `experiments belong in the prod environment`) | Sandboxes in the prod environment, or experiments in a nonprod one | Move the file to an environment of the right tier |
| `Product consumers must be another domain or a consumer domain (consumer domains only in the prod environment): ...` / validator `consumer domain 'x' can only be approved in prd` | A consumer domain approved in a nonprod environment, an unknown consumer, or a domain approved for its own product | Fix `entitlements/<env>/product_access.yaml` |
| Shared scope (`20`, `30` or `40`) fails reading `10-foundation/<first nonprod env>/env.tfstate`, with errors about missing outputs or an unreadable state **(cloud, unverified)** | Stack `40 shared` calls through the workspace of the first nonprod environment in alphabetical order (`dev` here). If that environment was torn down, the shared scope has no workspace to call | Rebuild that environment's `10 env` first (stack 40's shared scope needs it), or temporarily deploy shared from a checkout where another environment sorts first |
| Wildcard persona access (`dev:*:analyst`) does not reach a domain | `*` means "every domain that has that role"; the domain has no such role (for example a role added by another domain) | Name the domain explicitly, or add the role to that domain in `config/domain_shape/<domain>.yaml` |
| Validator: `<owner>: no domain defines role 'x' ('dev:*:x')` | The wildcard matches no domain at all | Fix the role name |

## Domain shape and access errors

From `scripts/validate_config.py` (and, with the same meaning, the naming module's `Domain shape errors:` / `Domain access errors:`).

| Message | Fix |
|---|---|
| `<d>: role 'x' collides with a standard or reserved role` | Pick another role name; `producer`, `analyst`, `ai`, `dbadmin` and `writer` are taken |
| `<d>: schema 'x' collides with a standard schema or uses the product_ prefix` | Choose a new name; `product_*` is reserved for products |
| `<d>: schema 'x' cannot be removed` | `admin` cannot be removed, and only standard schemas can be listed under `remove` |
| `<d>: schema 'x' needs a layer (...)` / `needs a comment` | Add `layer` (one of the listed values) and `comment` |
| `<d>: persona 'x' collides with a global persona` | Rename the domain persona |
| `domain_access/<d>: access given for unknown or protected schema 'x'` | The schema is not in this domain (it was removed or never added) or it is `admin` |
| `domain_access/<d>.<schema>: unknown role 'x'` | The role is not standard and not declared in `domain_shape/<d>.yaml` |
| `domain_access/<d>.<schema>.<role>: bundle 'RWC...' is above the ceiling 'RWC'` (module: `bundle above the ceiling`) | Use `R`, `RW` or `RWC`; `O` (owner) cannot be granted through overrides |
| `domain_access/<d>: access given for undeclared persona 'x'` | Declare the persona in `domain_shape/<d>.yaml` first |
| `persona <d>/<name> (<env>): domain persona may only reference roles of '<d>' ('<ref>')` (module: `a domain persona only its own domain's roles`) | A domain persona may only name its own domain's roles; it may not reference the vault |
| `persona X (<env>): '<ref>' reaches another environment than <env>` (module: `A persona may only reference its own environment's groups and workspaces`) | Fix the reference so it uses the environment of its `access.<env>` block |
| `persona X (<env>): platform group 'g' is not assigned to the <env> workspace` | Add `<env>: USER` under that group's `workspaces` in `config/personas.yaml` |
| `persona X: access.<env> is missing (use [] for no access)` | Every persona needs an `access` list for every environment |
| `<owner>: humans may not join prd producer groups ('prd:claims:producer'); use a service principal` (module: `Humans may not join prod-tier groups of service-principal-only roles`) | Humans can never be in service-principal-only roles in the prod environment (`producer`, plus any extra role with `service_principal_only: true`). Use the deploy service principal |
| `exactly one environment must have tier: prod` / `environment promotion cycle: a -> b -> a` / `environment 'x': promotes_from names unknown environment 'y'` | Fix the `environments:` block in `config/platform.yaml` |

## Product architecture

| Symptom | Likely cause | Fix |
|---|---|---|
| Stack 20: `azuread_users` fails | `resolve_consumer_leads: true` but no lead exists in Entra | Create the leads or set the flag back to `false` |
| Consumer lead can't add members | Lead isn't an owner yet | Set `resolve_consumer_leads: true`, deploy `20 env` in the prod environment |
| Producer sees masked values | Expected: only SARs and writers are exempt | Add the producer group to the SAR in `config/entitlements/<env>/sars.yaml` if it really needs clear values, then deploy `25 access` |
| Consumer sees no schemas in a domain catalog | Not approved for any of its products | Add the consumer to the product in `config/entitlements/<env>/product_access.yaml`, deploy `25 access` |
| Product view fails for consumers | View reads the vault or a private schema the consumer can't reach | Build products as tables from the domain's business vault or marts |
| Dev can't read `prd_claims_anon` tables | External location binding blocks reads from dev | Bind the `<prod env>_claims_anon_root` external location read-only to the nonprod environment as well |
| Mask on a financial column fails | Column type is not castable to `DECIMAL(38,6)` | Use DECIMAL for columns tagged `sensitive_metric = financial` |
| dbt task can't find the catalog | `env` variable not set for the target | Set `variables.env` in the bundle target |

## Order problems (a target ran before the one it needs)

The full order is in `docs/OPERATIONS.md` ("Order matters"). In short: 10 env; 20 shared; 20 env; 20 each domain; 25;
Phase 4 by hand; 30 shared, env, domains; **then** 40 shared, env, domains; 50, 55, 60 env then domains; 70 prod env.

| Symptom | Cause | Fix |
|---|---|---|
| `20 env` or `25` cannot find a group such as `piq-mesh-governance` or `piq-metastore-admins` | Those are shared groups. A link into a shared group belongs to the **child's** scope, so the env run needs the shared group to exist already | Deploy `20 shared` first |
| `20 domain:<d>` cannot find a persona group `piq-<env>-persona-...` | The persona groups are made by `20 env`; the domain run owns the links that put them into the domain's roles | Deploy `20 env` for that environment first |
| `40 shared` fails: a group in a tag-assigner rule is not found or "principal does not exist" | The tag rules name the groups of **every** environment and domain. Some environment (or a new domain) has not had `20` and `30` yet | Deploy `20` and `30` (every domain scope and env) in every environment, then re-run `40 shared`. Also re-run it after adding an environment or domain |
| `40 domain:<d>`: tag assignment fails "value not allowed" for `piq_product`, `piq_domain` or `piq_source_system` | A new product, domain or vault source adds a tag value, and `40 shared` has not been re-run | Deploy `40 shared`, then retry |
| `60 domain:<d>`: policy creation fails because a function does not exist | The masking functions are made by `60 env` of the same environment, and the domain run came first | Deploy `60 env` first. Check with `SHOW FUNCTIONS IN <env>_platform.governance` |
| `40 domain:<d>`: external location creation fails because storage credential `<env>_lake_credential` does not exist | That credential is made by `40 env` of the same environment | Deploy `40 env` first |
| `40` or `60` fails on a grant to the new domain's group | The new domain's groups were not resolved into the account | Deploy `30 domain:<d>` and `30 env` (the vault grants name every domain's groups), then retry |
| `55` fails reading `30-account/<env>/<scope>.tfstate` | Stack 55 reads the usage policies of the same scope from stack 30 | Deploy `30-account` for that exact scope first |
| `50`, `60`, `70` fail reading `10-foundation/<env>/env.tfstate` or `50-workspace/<env>/env.tfstate` | The environment's foundation or workspace stack has not run | Deploy `10 env` (then `50 env`) for that environment |

## Useful commands

```bash
az account show                                   # which identity Terraform will use
./scripts/tf.sh 40-unity-catalog --env dev --scope domain:claims init
./scripts/tf.sh 40-unity-catalog --env dev --scope domain:claims state list | head
./scripts/tf.sh 30-account --env dev --scope env plan -target='databricks_mws_permission_assignment.group'
databricks auth describe --host <workspace-url>   # Databricks CLI identity check
python3 scripts/status.py --env prd               # which release is deployed where
python3 scripts/plan_all.py --env dev --stack 40-unity-catalog   # what would change (read-only)
make plan-test                                    # mocked plans of every target; skips a stack if its provider cannot be downloaded
```

`tf.sh` needs `init` for a target before other commands (the wrappers `plan.py` and `apply.py` do it for you).
