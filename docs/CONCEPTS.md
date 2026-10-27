# Concepts: what each stack does and why

This document explains what Terraform is doing in plain terms, what Databricks
concepts are involved, and why the stacks are structured the way they are.
Read it alongside the RUNBOOK — the RUNBOOK tells you *what to run*, this tells
you *what is happening*.

> **What has been proven so far.** Everything below is checked by tests that need
> no cloud access: the naming tests (`tests/naming/run_tests.py`), the wrapper
> tests (`tests/wrappers/run_tests.py`), mocked plans of every stack for every
> target (`tests/stacks/run_plan_tests.py`) and `terraform validate`. Nothing from
> the scope, release and entitlement design has been applied to real Azure or
> Databricks yet. The first real apply will be the first real proof.

---

## Terraform basics

**What Terraform is:** a tool that lets you describe infrastructure in code (`.tf`
files) and then creates, updates or deletes real cloud resources to match that
description. Instead of clicking through Azure portal screens, you write what you
want and Terraform figures out the steps.

**State:** Terraform keeps a file (`.tfstate`) that records what it has already
created. On each run it compares the `.tf` files (what you want) against the state
(what it knows exists) and calculates the minimum changes needed. This is why
`plan` shows you a diff, not a full list of everything.

State is also Terraform's **scope of attention**. A run reads and changes only what
is in its state, so one big state means every run looks at everything. See
[Scopes](#scopes-and-targets-what-one-run-owns) for why this repo splits it.

**Remote state:** after bootstrap, all state files are stored in an Azure Storage
container instead of on your laptop. CI (GitHub Actions) and your local machine
share the same view of what exists.

**`terraform_remote_state`:** a later stack sometimes needs a value an earlier
stack created — for example, the workspace URL. It reads it from the earlier
stack's state with `terraform_remote_state`. This is why stacks run in order.
(Where a value is only a *name*, this repo does not read another state at all: the
naming module can compute the name. See [Names, not state](#names-not-state).)

**Providers:** Terraform talks to cloud APIs through plugins called providers.
This repo uses three: `azurerm` (Azure resources), `azuread` (Entra ID / Azure
Active Directory), and `databricks` (Databricks API).

---

## Scopes and targets: what one run owns

**The problem.** If every domain lives in one state, applying a change for
`claims` also compares and applies anything pending for `policy_financial`. You
cannot ship one domain's change on its own.

**The fix.** Every resource belongs to exactly one **scope**. A run owns one scope
and has its own state, so it cannot touch anything outside it.

| Scope | What it owns | Needs an environment? |
|---|---|---|
| `shared` | Things that span every environment: the governed tag definitions, the platform groups that serve every environment (`mesh-governance`, `platform-monitoring`, `metastore-admins`), the AI Gateway budget | No |
| `env` | One environment's infrastructure: network, workspace, storage, the environment's one storage credential, its vault / platform / sandbox / consumer catalogs, its global persona groups, its settings | Yes |
| `domain:<name>` | One domain in one environment: its catalog, schemas, grants, warehouse, masks, role groups, product groups, deploy service principal | Yes |
| `access` | People and approvals in one environment (stack 25): who is in which group | Yes |

A **target** is the triple *(stack, environment, scope)*. For example
`40-unity-catalog` + `prd` + `domain:claims` means "the Unity Catalog objects of the
claims domain in prd".

### Worked example

You add a schema to `claims` and want it in dev first, then prd.

```
Dev:  apply 40-unity-catalog / dev / domain:claims      -> changes dev_claims only
Prd:  apply 40-unity-catalog / prd / domain:claims      -> changes prd_claims only
```

`policy_financial` is never part of either run. Its state files
(`40-unity-catalog/dev/domain-policy_financial.tfstate`, ...) are not even opened.

### Where the state lives

| Scope | State file in the state container |
|---|---|
| `shared` | `<stack>/shared.tfstate` |
| `env` | `<stack>/<env>/env.tfstate` |
| `access` | `<stack>/<env>/access.tfstate` |
| `domain:<name>` | `<stack>/<env>/domain-<name>.tfstate` |

The key is worked out in one place (`util/scope.py`, used by `scripts/tf.sh` and
`scripts/state_key.py`).

### Which stack supports which scope

Each stack declares its scopes in `stacks/<stack>/stack.yaml`.

| Stack | Scopes | Notes |
|---|---|---|
| `10-foundation` | env | |
| `20-identity` | shared, env, domain | |
| `25-access` | access | people and approvals only |
| `30-account` | shared, env, domain | |
| `40-unity-catalog` | shared, env, domain | |
| `50-workspace` | env, domain | |
| `55-ai-platform` | env, domain | |
| `60-governance` | env, domain | |
| `70-observability` | env | prod environment only |

### Names, not state

Scopes need to refer to each other. A claims run grants something to the group
`piq-prd-product-loss`, and a prd env run references the credential
`prd_lake_credential`. Neither run reads the other's state. The naming module
computes the same name from `config/`, so every run agrees on it. The thing being
named must already exist, which is why scopes have an order (see the RUNBOOK).

### Who owns a group-in-group link

A **nesting edge** puts one group inside another (the *child* is a member of the
*parent*). The edge belongs to the scope of its **parent**, because the parent is
the group that grants the access. There is one exception: an edge into a **shared**
group belongs to the **child's** scope, so the `shared` scope never depends on an
environment. If the other end belongs to a different scope, the run finds it by its
display name. Examples: the persona group `piq-prd-persona-data-analyst` belongs to the
`env` scope; the link into `piq-prd-claims-analyst` belongs to `domain:claims`, so a new
domain's first run creates its own links. The link from that persona into the shared
group `piq-metastore-admins` (for `platform-admin`) belongs to `prd/env`, so adding an
environment never means re-running `shared`.

### How we know the split is right

Two tests (no cloud needed):

- **Partition test** (`tests/naming/run_tests.py`): evaluates the naming module once
  per scope and proves every item belongs to exactly one scope, and that the scopes
  together cover everything.
- **Mocked plans** (`tests/stacks/run_plan_tests.py`): plans each stack for every
  target. The number of resources planned across all of a stack's targets equals
  what a plan of the whole stack at once would show (for example 347 for `40-unity-catalog`).
  Nothing was lost and nothing is counted twice.

---

## Environment tiers

Rules in this repo depend on an environment's **tier**, never on its name. Each
environment in `config/platform.yaml` declares `tier: nonprod` or `tier: prod`.
Exactly one environment must be `prod`.

| Rule | Where it applies |
|---|---|
| Humans cannot join service-principal-only roles (`producer`, plus any extra role flagged `service_principal_only`) | The prod environment |
| Consumer domains, and the writer of anonymized catalogs, live here | The prod environment |
| Approved experiments live here | The prod environment |
| Personal sandboxes live here | Nonprod environments |
| Anonymized prod data can be read from here | Every nonprod environment |
| Compute policies marked `nonprod_only` are skipped here | The prod environment |

Because of this, adding `qa`, `uat` or `dev2` is a config change: add an entry to
`environments:` with `tier: nonprod` and a network block. The environment names
you use today (`dev`, `prd`) are only labels.

---

## Releases and promotion

**Release tag.** A git tag named `rel-YYYY.MM.DD.N` (for example `rel-2026.10.23.1`)
on a commit. It is a frozen snapshot. `scripts/release.py` (or the `release`
workflow) creates it after the config validates.

**Branching.** `main` is the only long-lived branch. Work happens on short-lived
branches merged by pull request. There are no `dev` or `prd` branches: environments
differ by which snapshot is deployed to them, not by branch.

**Promotion.** Moving a release from one environment to the next. Each environment
in `platform.yaml` lists `promotes_from`: the environments a release must already
have been deployed to.

```yaml
environments:
  dev: { tier: nonprod, promotes_from: [],    allow_hotfix: false }
  prd: { tier: prod,    promotes_from: [dev], allow_hotfix: true }
```

It is a graph, not a line. A future setup could say `qa: promotes_from: [dev1, dev2]`
and `prd: promotes_from: [uat]`.

**Promotion gate.** Before an apply, `scripts/apply.py` checks the deploy records:

1. An environment with `promotes_from` accepts only a release tag, not a plain commit.
2. HEAD must be that tag's commit and the working tree must be clean, so the code
   that runs is the code that was released.
3. A record with outcome `PASS` for the same release, **same stack and same scope**,
   must exist for **every** environment in `promotes_from`. Claims reaching dev says
   nothing about `policy_financial`.

An environment with an empty `promotes_from` (dev) accepts any commit.

**Deploy records.** Every apply writes a record (release, commit, stack,
environment, scope, who, outcome) to the `deployments` container in the state
storage account (`util/deploys.py`). `scripts/status.py` shows the latest successful
release of every target.

**Empty plans count.** If a release changes nothing for a domain, the plan is
empty. The release is still recorded as deployed, otherwise it could never be
promoted for that domain.

**Hotfix.** `--hotfix --approver NAME` skips the gate, only in an environment with
`allow_hotfix: true`, and records the approver. Afterwards replay the release through
the environments it skipped and merge the fix to `main`.

**Several dev releases per prod release** is normal: any commit can go to dev;
only the ones you tag can go on.

---

## The scope check

A second lock behind the state split. Before anything is applied it asks: "does this
plan change only what this target owns?"

How it works, step by step:

1. Terraform writes the plan to a file. The wrapper converts it to JSON.
2. The wrapper evaluates the naming module in full. Every item it produces carries an
   `sid`: `shared`, `<env>/env`, `<env>/domain:<name>` or `<env>/access`.
3. For every resource the plan would create, change or delete, the wrapper reads its
   instance key (for a schema: `domain:prd:claims/product_loss`) and looks up the owner.
4. If an owner differs from the target's own `sid`, the plan is refused (exit code 4).

Example failure when deploying `40-unity-catalog` / `prd` / `domain:claims`:

```
SCOPE CHECK FAILED: the plan changes things this target does not own:
  - module.uc[0].databricks_schema.this["domain:prd:profitability/product_loss_ratio"]
    belongs to prd/domain:profitability, this run owns prd/domain:claims
```

Resources with no instance key (workspace settings) belong to the run. A key the
naming module does not recognise is reported as a note, not a failure. Code:
`util/scope_check.py`.

---

## Deployment tooling

Python scripts wrap the raw Terraform workflow and add validation, checks and
records. Every one takes the target: `<stack> --scope <scope> [--env <env>]`.

| Script | What it does |
|---|---|
| `scripts/tf.sh` | Runs Terraform for one target with the right state key. `init` always re-configures, so switching targets is safe |
| `scripts/plan.py` | Plans one target, saves the plan to a git-ignored file next to the stack, prints it, runs the scope check. Makes no changes. Exit 0, 1 (failed), 4 (scope check) |
| `scripts/apply.py` | The full workflow: release check, promotion gate, plan, scope check, confirmation, apply **the saved plan**, checks, deploy record. `--yes` is only allowed together with `--plan FILE`, so a pipeline applies a plan a person already read. Exit 0, 1, 2 (declined), 4 (scope), 5 (promotion gate) |
| `scripts/check.py` | Runs only the post-apply checks of a deployed target |
| `scripts/plan_all.py` | Plans every target of an environment, read-only, and tabulates which have changes. Used on pull requests and nightly to find drift |
| `scripts/release.py` | Cuts the next `rel-*` tag (`--push`, `--list`) |
| `scripts/status.py` | Shows which release is deployed where |
| `scripts/provision_access.py` | Turns an approved access request into an entitlement edit (needs `--env`) |

**`util/`** is the Python package they share:

- `util/scope.py` — scopes, state keys and target validation.
- `util/naming_eval.py` — the one evaluator of the naming module. Tests, mocked
  plans, the scope check and the post-apply checks all use it, so there is no second
  copy of the naming rules in Python.
- `util/targets.py` — resolves and lists targets from config.
- `util/tfrun.py` — runs Terraform for a target through `scripts/tf.sh`.
- `util/scope_check.py`, `util/deploys.py`, `util/release.py` — the scope check, the
  deploy records with the promotion gate, and release tags.
- `util/validation.py` — `Context`, `CheckResult` (`PASS` / `FAIL` / `RETRY`) and the
  retry runner. `RETRY` means a known transient condition (for example the AIM sync
  delay): the runner waits 15 seconds and tries again, up to 5 times.

Each stack has `stacks/<n>/checks.py` with a `CHECKS` list. A check receives the
target's Terraform outputs and a `Context` (the target plus the naming output for it:
what this run was supposed to create) and returns a `CheckResult`.

**Pipelines** (`.github/workflows/`):

| Workflow | Does |
|---|---|
| `validate` | Every PR, no cloud credentials: config, `terraform fmt`, naming and wrapper tests, mocked plans, `terraform validate` |
| `plan` | Every PR: plans every target of the first nonprod environment and comments what would change |
| `deploy` | By hand: a **plan** job, then (after approval, required on the prod environment) an **apply** job that applies that saved plan |
| `release` | By hand: runs the checks, then tags the commit |
| `drift` | Nightly, plan only: reports changes nobody merged |
| `provision-access` | An approved access-request issue becomes a pull request on `config/entitlements/` |

---

## The naming module

Before any stack does anything, it calls `module "naming"`. This module reads every
YAML file in `config/` and derives every name, group, grant, catalog, schema and
warehouse from them. It creates nothing — it is pure computation. Every stack uses
its outputs so that a group name or catalog name is spelled the same way everywhere.

The module is **always computed in full**. Its `environment` and `scope` inputs only
filter what it *returns*, to the slice one run owns. That is how a run can still
compute the name of a group another scope owns.

If you change something in `config/`, re-running any stack will pick it up because
the naming module is re-evaluated every time.

---

## Definitions versus entitlements

Two different jobs:

- **Definitions:** which groups exist and what each may do on data. Example: "the
  `analyst` role of claims gets `SELECT` on `info_mart`." This is infrastructure and
  lives in stacks 20 to 60.
- **Entitlements:** who is in which group, and which access requests were approved.
  Example: "jane is a data-analyst in prd", "profitability may read the `loss`
  product", "`exec_reporting` analysts hold the `financial_metrics` SAR."

Entitlements live in `config/entitlements/<env>/` and are applied only by stack
`25-access`. The stack creates the groups empty (stack 20); stack 25 fills them.

**Why separate them.** In most companies an identity-governance tool (SailPoint,
Saviynt, PingID) decides who gets which role and writes it into Entra. This repo has
no such tool yet, so `config/entitlements/` and stack 25 stand in for it.

**How a tool replaces it.** Delete `config/entitlements/` and stack 25. The tool
manages membership of the same Entra groups. Nothing else changes, because the
group **names** are the contract between the two.

(One loose end: sandbox users and experiments also create schemas, which stack 40's
`env` scope reads from the entitlements. When a tool takes over, those two need a
self-service path of their own.)

---

## Personas

A **persona** is a job role such as `data-engineer`. It has the same shape
everywhere but its own access in each environment. For each environment Terraform
creates one Entra group per persona, and nests it only into that environment's
groups.

```yaml
data-engineer:
  access:
    dev: ["dev:*:producer", "sandbox-users"]   # builds in dev
    prd: ["prd:*:analyst"]                     # read-only in prd
```

This creates `piq-dev-persona-data-engineer` and `piq-prd-persona-data-engineer`.
Nothing links the dev one to prd, so a person can be a `data-engineer` in dev and
only a `data-analyst` in prd. Who holds which persona is an entitlement
(`config/entitlements/<env>/personas.yaml`).

A persona may only reference its own environment's groups and workspace; the check
runs in both the naming module and the validator. In the prod environment it cannot
nest into a service-principal-only role.

**Domain personas.** A domain can add personas of its own (see below). Their groups
are `piq-<env>-persona-<domain>-<name>` and they may only reference their own
domain's roles.

### Group keys

Groups are identified by keys: `"<env>:<domain>:<role>"` (`prd:claims:producer`),
`"writer:<env>:<domain>"`, `"product:<env>:<product>"`, `"consumer:<consumer>:<role>"`,
`"vault:<env>:<role>"`, `"sar:<env>:<sar>"`, `"platform:<key>"`,
`"persona:<env>:<name>"` and `"persona:<env>:<domain>:<name>"`. The same keys are used
in nesting, grants and workspace assignments.

---

## Domain shape and domain access

Every domain gets the **standard**: the schemas in `config/domains.yaml`, the roles
and privilege matrix in `config/access_matrix.yaml`, and the global personas. A domain
can differ from the standard in two ways, in two files, because two different groups
decide:

| File | Decides | Approved by |
|---|---|---|
| `config/domain_shape/<domain>.yaml` | What exists: extra schemas (or removing a standard one), extra roles, extra personas. Names and descriptions only | The domain team |
| `config/domain_access/<domain>.yaml` | What it may do: schema access per role, product access, warehouse use, persona access per environment | Platform and governance |

Declaring a role grants nothing. Example: claims declares an `adjuster` role in the
shape file; the access file says `adjuster` gets `R` on the new `adjuster_notes`
schema. Only claims gets those groups and that schema.

Limits (checked by the validator and the naming module): a bundle can never exceed
`override_ceiling` (`RWC`), the `admin` schema cannot be removed or changed, names
cannot collide with standard or reserved ones, and a domain persona may only
reference its own domain's roles. A bundle may differ by tier: `{nonprod: RW, prod: R}`.

Because schema names carry no environment, a new schema reaches prd by promoting a
release.

---

## Bootstrap (run once, locally)

**What it creates:**
- A **storage account** in Azure (`stpiqtfstate...`) with a container called `tfstate`.
  This is where all state files live.
- One **resource group per environment** (`rg-piq-dev`, `rg-piq-prd`), so Azure rights
  can be limited to it.
- **Terraform identities** (Entra app + service principal, think "robot account"):
  `sp-piq-terraform` for the shared scope and account-wide work, and
  `sp-piq-terraform-<env>` for each environment. Each environment's robot has Azure
  `Contributor` and `Role Based Access Control Administrator` on **that environment's
  resource group only**.
- **OIDC federated credentials** — a trust rule that says "when a GitHub Actions job
  runs in this repo's GitHub environment `<env>` (apply) or `<env>-plan` (plan), it may
  act as `sp-piq-terraform-<env>` without a password." The shared identity trusts
  `shared` and `shared-plan`.

**Honest limits of the separation.** The dev robot cannot change prd's Azure resources.
But Microsoft Entra and the Databricks account only offer all-or-nothing rights: the
Graph permissions and Databricks account-admin role cannot be limited to one
environment, and rights on the state storage account are account-wide. So a dev robot
is not technically blocked from prd groups; the pipeline rules stop it. Entra
*administrative units* (CR-001) would close the first gap, per-environment state
containers the second.

**Why it runs locally:** the robots don't exist yet, so CI can't run. You run it once
as yourself (your `az login` session), then hand off to CI.

---

## Stack 10-foundation — Azure infrastructure

Scope: `env`. One run per environment.

**What it creates:**

| Resource | Purpose |
|---|---|
| Virtual network + subnets | The private network Databricks cluster nodes run inside. Two subnets per workspace: "host" (where nodes live) and "container" (internal Databricks traffic) |
| Databricks workspace (`dbw-piq-dev`, `dbw-piq-prd`) | The actual Databricks workspace. Premium tier enables Unity Catalog and serverless compute |
| Storage account (`stpiqdev...`, `stpiqprd...`) | ADLS Gen2 — Azure's data lake storage. Unity Catalog stores all table data here, one storage container per catalog (including every domain's) |
| Access Connector (`ac-piq-dev`, `ac-piq-prd`) | A managed identity that Unity Catalog uses to read/write the storage account. No passwords — Azure handles auth internally |
| Key Vault | For any secrets that can't use OIDC (currently reserved for future use) |

The resource group itself (`rg-piq-<env>`) is created by bootstrap and only looked up here.

**Why VNet injection?** By default, Databricks runs cluster nodes on Microsoft's
network. VNet injection puts them inside your own Azure Virtual Network, so you
control network access, firewall rules, and private connectivity to other Azure
services. It also means no public IPs on cluster nodes.

**Side effect:** creating the first Premium workspace automatically creates your
Databricks *account* — the account-level console at
`https://accounts.azuredatabricks.net`.

---

## Stack 20-identity — Entra groups and service principals

Scopes: `shared`, `env`, `domain:<name>`.

**What it creates:**

| Resource | Purpose |
|---|---|
| Entra security groups (`piq-dev-claims-producer`, etc.) | One group per environment × domain × role (including a domain's extra roles), plus writer, vault, product, SAR, consumer, platform and persona groups. These become the access control principals for everything in Databricks |
| Persona nesting | Each persona group is nested into the role groups listed in its `access` for that environment |
| Per-domain service principals (`sp-piq-dev-claims-deploy`, etc.) | The robot account for each domain's CI pipeline. Each one has an OIDC trust for its domain's GitHub repo |
| Vault loader SP | The identity that writes to the shared raw vault |
| Test users | Training-only Entra users (test.analyst, test.engineer, etc.) with auto-generated passwords |

Who is **in** the groups is not decided here: see
[Definitions versus entitlements](#definitions-versus-entitlements).

**Key concept — Entra as the source of truth for identity:** all groups live in
Microsoft Entra ID (formerly Azure Active Directory). Databricks does not maintain
its own copy — it reads from Entra automatically via **Automatic Identity Management
(AIM)**. This is why, after stack 20 runs, you see those groups appear in the
Databricks account console with the "In Microsoft Entra ID" label.

**Key concept — AIM sync delay:** AIM does not propagate group membership
instantaneously. After groups or memberships change, allow roughly one minute
before running stacks that depend on them (stack 30, stack 50). If a stack fails with
a "user does not have permission" error immediately after, wait a minute and retry.

**Key concept — the platform-admin persona and the `system` catalog:** stack 50
grants `piq-platform-monitoring` the ability to read Databricks system tables (audit
logs, query history, cost records). That grant requires MANAGE on the `system`
catalog, which only metastore admins have. The grant runs as the environment's
Terraform identity, which is in `piq-metastore-admins`.

Metastore admin is held by the group `piq-metastore-admins`. The Terraform identities
are added to it by stack 20's `shared` scope. People get into it by holding the
`platform-admin` persona, which is nested into `piq-metastore-admins`. Add your
**UPN** (User Principal Name) to `config/entitlements/<env>/personas.yaml`:

```yaml
users:
  you@yourdomain.com: [platform-admin]
```

**What a UPN is:** the login name of a user in Microsoft Entra ID. It looks like an
email address (`you@yourdomain.com`) and is unique across your tenant. It is the
value you used when you first signed in to Azure. You can confirm yours with:
```bash
az ad signed-in-user show --query userPrincipalName -o tsv
```

**Key concept — OIDC for domain SPs:** just like the Terraform identities, each
domain deployer SP has no password. Its CI pipeline authenticates by presenting a
GitHub-issued token, and Azure checks whether the token matches the trust rule for
that repo and environment.

---

## Stack 25-access — who is in which group

Scope: `access`. One run per environment, after stack 20 of the same environment.

Reads `config/entitlements/<env>/` and applies it: persona assignments, domain
admins, sandbox users, experiment members, product approvals (a consumer group
nested into a product group) and SAR members. It finds every group, user and test
user by name, because they already exist. It does not create groups.

---

## Stack 30-account — Databricks account configuration

Scopes: `shared`, `env`, `domain:<name>`.

This stack operates at the **Databricks account level**, not inside any workspace.
The account is the parent of all workspaces and is where cross-workspace things live.

**What it creates:**

| Resource | Purpose |
|---|---|
| AIM resolution | Reads each Entra group/SP the run's objects name into the Databricks account so it can be referenced in grants. This is the step that formally registers identities with Databricks. Groups, SPs and users are found in Entra by name |
| Workspace assignments | Adds groups and SPs to the workspace of the run's environment with USER or ADMIN permission |
| Serverless usage policies | Tags every serverless DBU (Databricks Unit — the billing unit for compute) with `piq_env` and `piq_domain`. This is how you know which domain incurred which cost |
| Budgets | Alert-only cost budgets per environment and per domain. They email `ops_email` when spending crosses the configured percentages of the monthly limit. They do not cut off compute. The single AI Gateway budget is in the `shared` scope |
| Egress network policies | Controls which external URLs serverless compute can reach. Starts in `DRY_RUN` (logs violations but doesn't block) so you can see what your code actually calls before enforcing |

**Why a separate account stack?** Workspace assignments and usage policies are
account-level Databricks API calls — they don't exist inside a workspace. Keeping
them in their own stack makes it clear what requires account-admin credentials vs.
workspace-admin credentials.

---

## Stack 40-unity-catalog — catalogs, schemas, grants and tags

Scopes: `shared`, `env`, `domain:<name>`.

Unity Catalog is Databricks' central governance layer — a single place to manage
all data assets (tables, views, volumes, models) across all workspaces, with
fine-grained access control.

**Three-level namespace:** everything in Unity Catalog lives at
`catalog.schema.table`. A catalog is like a database-of-databases; a schema
(also called a database) groups related tables.

**What it creates, by scope:**

| Scope | Resources |
|---|---|
| `shared` | Governed tags (the taxonomy, e.g. `pii`, `sensitive_metric`). They exist once for the whole account. Databricks only lets you create them through a workspace, so this scope calls through the first nonprod environment's workspace |
| `env` | The environment's one **storage credential** (the key that lets Databricks reach the storage account), and the vault, platform, sandbox and consumer-prep catalogs with their schemas and grants |
| `domain:<name>` | The domain's catalog (`dev_claims`), its private and product schemas, volumes, grants, tags, and its anonymized catalog if `anon: true`. It points at the environment's credential by name |

Other things every catalog gets: a storage location bound to its storage container,
and grants derived from `config/access_matrix.yaml` (plus the domain's overrides).

**Key rule — product isolation:** a product group gets `USE CATALOG` but not
`BROWSE` on a domain catalog. This means a consumer can query their approved product
schema but cannot list or discover other schemas in that catalog.

**Key rule — no environment in schema names:** schemas are named `product_loss`,
not `dev_product_loss`. The same dbt model runs in dev and prd unchanged.

---

## Stack 50-workspace — warehouses and compute policies

Scopes: `env`, `domain:<name>`.

**What it creates inside the environment's workspace:**

| Resource | Scope | Purpose |
|---|---|---|
| SQL Warehouses | domain: the domain's `piq-claims-transform`. env: `piq-vault-load`, `piq-shared`, and one per consumer domain (`piq-exec-reporting-bi`, prod only) | Serverless SQL compute endpoints |
| Compute policies | env | Cluster policies that restrict what kinds of clusters domain users can create (size limits, auto-termination, required tags) |
| IP access lists, workspace settings | env | If configured in `platform.yaml`, restricts workspace login to specific CIDRs |
| System table access | env of the prod environment | Lets the monitoring group read Databricks system tables (audit logs, query history, cost data) that stack 70 queries |

**What a SQL warehouse is:** a pool of serverless compute that runs SQL queries.
It scales up when queries arrive and scales to zero when idle — you only pay while
it's running queries. Each domain has its own warehouse so costs are attributed
correctly and one domain's heavy query load doesn't affect another.

---

## Stack 55-ai-platform — AI infrastructure

Scopes: `env`, `domain:<name>`.

| Resource | Scope | Purpose |
|---|---|---|
| Vector search endpoint | env | For domains using embeddings and semantic search |
| App Spaces | domain | Databricks Apps hosting environment — for domains with `app_space: true` in `domains.yaml` |
| Lakebase | domain | For domains with `lakebase: true` — a managed Postgres-compatible database backed by the lakehouse |

These are optional per-domain features controlled by flags in `config/domains.yaml`.
A run reads the usage policies made by stack 30 in the same scope.

---

## Stack 60-governance — column masking

Scopes: `env`, `domain:<name>`.

**What it creates:**

| Resource | Scope | Purpose |
|---|---|---|
| Masking SQL functions | env | SQL functions like `mask_ssn()`, `mask_dob()` stored in `{env}_platform.governance`. They return a redacted value (e.g. `***-**-1234`) unless the caller is in an exempt group |
| ABAC column mask policies | the catalog's scope | Attaches each masking function to each catalog, triggered by governed tags. For example: any column tagged `pii=ssn` in `prd_claims` is automatically masked for everyone except the `claimant_pii` SAR group and the claims writer SP |

The `env` scope must run first: a domain's policies call the functions it creates.

**How masking works end to end:**
1. A data engineer tags a column: `ALTER TABLE ... SET TAGS ('pii' = 'ssn')`
2. Stack 60 has already applied a policy: "on catalog `prd_claims`, mask any column
   where `has_tag_value('pii', 'ssn')` using `mask_ssn()`, except for SAR group
   `piq-prd-sar-claimant-pii` and the claims writer SP"
3. A producer analyst queries that column — they see `***-**-1234`
4. The same analyst joins the `claimant_pii` SAR (via a pull request on
   `config/entitlements/prd/sars.yaml`, approved by governance) — they now see the
   real value

Nobody writes custom per-table access rules. The masking follows the tag automatically
across every column in every table in that catalog.

---

## Stack 70-observability — monitoring views

Scope: `env`, in the prod environment only (system tables are account-wide, so one
set of views covers every environment).

**What it creates:**

SQL views in `<prod env>_platform` (`prd_platform`) over Databricks system tables.
System tables are Databricks-managed tables that record everything that happens in
your account: every query, every job run, every permission change, every cost record.

| View | What it shows |
|---|---|
| `monitoring.cost_daily_by_env_domain` | Daily spend broken down by environment and domain tag |
| `monitoring.cost_untagged_usage` | Compute that ran without `piq_domain` tags — a signal that something bypassed the usage policies |
| `audit.denied_requests` | Permission-denied events — who tried to access what and was refused |
| `audit.permission_changes` | Every grant and revoke |
| `governance.pii_columns` | All columns currently tagged with PII tags |
| `governance.lineage_recent` | Data lineage — which tables read from which other tables |
| `governance.products` | The published product catalog |
| `observability.query_activity_daily` | Query volume and latency by warehouse |
| `observability.job_run_outcomes` | Job success/failure rates |

These views are created by running SQL files through the Databricks Statement
Execution API (via `scripts/run_sql.py`). Terraform re-runs the SQL whenever the
file changes.
