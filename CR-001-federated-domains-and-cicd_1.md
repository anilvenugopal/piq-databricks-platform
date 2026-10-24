# CR-001: Federated domain execution and end-to-end CI/CD

| | |
|---|---|
| Repository | `anilvenugopal/piq-databricks-platform` (plus new domain and vault repositories) |
| Author | Anil Venugopal |
| Date | 22 October 2026 |
| Status | In Review — decisions resolved 2026-10-22 |

---

## 1. Objective

1. **Federate execution to domains.** The central platform team owns the platform repository and creates each domain's space: catalog, storage, base groups, deployment identity, compute and delegated rights. Each domain then runs everything inside that space from its **own** repository, with its **own** identity: schemas, data products, product groups, consumer approvals, tables, pipelines and tags. Domains get exactly the rights they need for their own space and nothing beyond it.
2. **Complete the CI/CD path.** Every change, whether platform or domain, reaches dev and prd only through a reviewed pipeline, with no stored secrets and no manual steps after approval.
3. **Fix the issues found during review**: a committed state file, a Terraform version mismatch, missing product contracts, and prd write rights held by people.

---

## 2. Summary of changes

| ID | Change | Priority | Depends on |
|---|---|---|---|
| CR-1 | Remove the committed bootstrap state file from history and fix `.gitignore` | **Urgent** | none |
| CR-2 | Use one Terraform version everywhere | High | none |
| CR-3 | Federated domain execution (platform side) | High | Decisions D1–D4 |
| CR-4 | Domain repository template with infrastructure and deployment pipeline | High | CR-3 |
| CR-5 | Create the domain repositories | High | CR-4 |
| CR-6 | Vault loading repository and pipeline | Medium | CR-4 |
| CR-7 | Anonymization job for `prd_{domain}_anon` | Medium | CR-5 |
| CR-8 | Apply platform changes automatically after approval | Medium | CR-2 |
| CR-9 | Data product contracts | Medium | CR-4 |
| CR-10 | Remove write rights from people in prd domain admin groups | Medium | none |

Section 4 lists the decisions to take before CR-3 starts. Section 3 covers current state and cleanup.

---

## 3. Before you start: current state and cleanup

The changes below are mostly code. Terraform manages every object the platform has created, so it can show exactly what moves and what doesn't. A careful order means nothing is left behind to clean up by hand.

### 3.1 Find out what has been applied

The bootstrap stack has been applied (its state is in the repository; see CR-1), and lock files exist for stacks 10–40. Run this from the repo root to see which stacks hold resources:

```bash
for s in 10-foundation 20-identity 30-account 40-unity-catalog 50-workspace 55-ai-platform 60-governance 70-observability; do
  ./scripts/tf.sh $s init -input=false >/dev/null 2>&1 && echo "== $s: $(./scripts/tf.sh $s state list 2>/dev/null | wc -l) resources"
done
```

### 3.2 What is affected

| Area | Effect of this CR | Cleanup |
|---|---|---|
| Stack 10 (Azure) | Adds state containers per domain. Nothing removed | None |
| Stack 20 (Entra) | Product groups and product-consumer nesting move to domain repositories. Administrative units are added | Move or recreate (3.3) |
| Stack 30 (account) | Registers domain-created groups. Nothing removed | None |
| Stack 40 (Unity Catalog) | Private and product schemas in **domain** catalogs, with their grants and tags, move to domain repositories. Catalogs, vault, platform, consumer, anon and sandbox catalogs stay | Move or recreate (3.3) |
| Stacks 50–70 | No resources move | None |

### 3.3 Two migration paths

Pick one for each environment, based on what 3.1 shows.

**Path A: preserve (use when the moved objects hold real data or real members).**
1. In the platform stack, take each moving object out of platform state without deleting it, using `terraform state rm '<address>'`. A `removed` block cannot be used here because Terraform's `removed` block cannot target single instances of a `for_each` resource, and product groups and domain schemas share resources with objects that stay.
2. In the domain repository, adopt the same objects with `import` blocks. Groups keep their object IDs, schemas keep their tables, and grants stay as they are.
3. Ship this as a script (`scripts/migrate_cr001.sh`) generated from `state list` output, listing every address, so the move is reviewed in a pull request and repeatable for prd.

**Path B: recreate (use when the account is a training account with no data worth keeping).**
1. Apply the platform change. Terraform destroys the domain schemas and product groups it no longer manages. Schemas that contain tables must be emptied first; Terraform refuses to drop non-empty schemas unless `force_destroy` is set.
2. Run the domain pipeline, which creates them again under domain ownership. Groups get new object IDs. Nothing else references them.

**Acceptance for either path:**
- After migration, `plan` on stacks 20 and 40 shows **no changes**.
- `plan` in each domain repository shows **no changes**.
- Under Path A, no plan at any point shows a destroy of a moved object.

---

## 4. Decisions resolved 2026-10-22

| ID | Decision | Resolution | Rationale |
|---|---|---|---|
| D1 | Who creates the private schemas (`business_vault`, `info_mart`, `reporting`, `sandbox`, `ai`, `event_log`) | **(a) The domain**, through the enabler module, with the standard set as the default. Platform keeps only the `admin` schema. | The domain owns its whole catalog below the catalog level. The standard set still comes from the platform's module, so the platform controls the shape without controlling the execution. |
| D2 | How domain repositories get the enabler module | **(a) Separate public GitHub repository.** The module holds no tenant IDs, environment values or credentials. | No stored secrets required. Any domain repository can reference it by URL. Simpler than a private repo or copying. |
| D3 | How domain-created groups register in Databricks, and the broader pattern for platform services consumed by domains | **Three-layer model — see below.** | Domains need multiple interaction patterns with the platform depending on the operation. A single mechanism does not cover all cases. |
| D4 | Scope of each administrative unit | **(b) One per domain per environment** (`au-piq-dev-claims`, `au-piq-prd-claims`). | The dev deployment identity must not be able to modify prd groups. Separate units enforce this at the Entra layer, not by convention. |

### D3 detail: platform-domain interaction model

Three patterns are used depending on the nature of the operation. This constitutes the platform's service catalog for domain consumption.

| Pattern | Mechanism | Used for | Not used for |
|---|---|---|---|
| **1. Terraform module (pull)** | Domain CI downloads the enabler module from the public module repo and runs it with the domain's own identity | Private schemas, product schemas, product groups, consumer nesting, grants and tags — all within the domain's own catalog and administrative unit | Anything requiring platform-level credentials |
| **2. Reusable GitHub Actions workflow (call)** | Domain pipeline calls a workflow defined in the platform repository; that workflow runs with platform credentials, not domain credentials. GitHub concurrency groups queue concurrent callers — no parallel execution risk. | Operations triggered synchronously by a domain pipeline that require platform credentials: central validation checks, future operations that cross domain boundaries | Long-running or multi-stack operations; anything the domain can do with its own identity |
| **3. Scheduled platform stack (async)** | Stack 30 runs on a schedule and pulls every group from domain administrative units into the Databricks account automatically | Group registration in the Databricks account (D3 original question). No domain action required; delay is bounded by the schedule interval | Anything the domain needs to happen synchronously during its own pipeline |

**Group registration specifically (original D3 question):** pattern 3 (scheduled stack 30) is the primary mechanism. AIM sync works and is confirmed in this account, but the schedule provides a reliable bounded interval rather than relying on eventual consistency. Pattern 2 (reusable GHA) is available for any future case requiring synchronous registration.

**Platform service catalog — responsibility boundary:**

| Responsibility | Owner | Mechanism |
|---|---|---|
| Catalog, storage, bindings | Platform | Platform stack 40 |
| Base groups (domain roles, writer, SAR, persona) | Platform | Platform stack 20 |
| Deploy service principal + OIDC trust | Platform | Platform stack 20 |
| Administrative unit + scoped Group Administrator role | Platform | Platform stack 20 |
| Catalog-users group | Platform | Platform stacks 20 + 40 |
| Warehouse, usage policy, budget | Platform | Platform stacks 30 + 50 |
| Governed tags, masks, SARs | Platform (governance) | Platform stacks 40 + 60 |
| Observability views | Platform | Platform stack 70 |
| Group registration in Databricks account | Platform (async) | Scheduled stack 30 (pattern 3) |
| Central uniqueness / cycle / contract checks | Platform | Scheduled platform workflow → reusable GHA (pattern 2) |
| Private schemas | Domain | Domain Terraform via enabler module (pattern 1) |
| Product schemas, grants, tags | Domain | Domain Terraform via enabler module (pattern 1) |
| Product groups (inside AU) | Domain | Domain Terraform via enabler module (pattern 1) |
| Consumer nesting | Domain | Domain Terraform via enabler module (pattern 1) |
| Tables, pipelines, jobs | Domain | Domain Asset Bundle |
| Column tags on tables | Domain | Domain pipeline (dbt or SQL) |
| Consumer group membership | Consumer lead | Directly in Entra |

---

## 5. Changes

### CR-1. Remove the committed bootstrap state file from history (urgent) — **DONE**

**Objective.** No Terraform state in Git.

**Finding.**
- `bootstrap/terraform.tfstate_backup` was committed at commit `bc39d37`.
- `.gitignore` covered `*.tfstate` and `*.tfstate.*` but not `*.tfstate_backup` (the suffix, not a second extension).
- The file contained storage account keys and connection strings for `stpiqtfstateav30`. Shared key access is disabled on that account, limiting exploitability.
- The repository is public.

**Change applied 2026-10-22.**
1. Purged the file from all history using `git filter-repo --path bootstrap/terraform.tfstate_backup --invert-paths --force`.
2. Added `*.tfstate_backup` to `.gitignore`.
3. Force-pushed to `main`. Commit `9aa09d9`.

**Key rotation:** not performed. Shared key access is disabled on the storage account; the keys in the state file cannot be used to authenticate. The account owner accepted this risk.

**Acceptance.**
- `git log --all -- bootstrap/terraform.tfstate_backup` returns nothing. ✓
- `.gitignore` now covers `*.tfstate_backup`. ✓

---

### CR-2. Use one Terraform version everywhere

**Objective.** Local runs and CI read and write the same state format.

**Finding.** The bootstrap state was written by Terraform **1.16.4**. The `validate`, `plan` and `apply` workflows pin **1.9.8**. If any stack was applied locally with 1.16, CI cannot read its state; Terraform refuses state written by a newer version.

**Change.**
- Pick one version (the one used locally).
- Set it in all four workflows (`terraform_version`), in `required_version` of bootstrap and every stack, and in RUNBOOK Phase 1.
- Domain repositories (CR-4) use the same version.

**Rationale.** A version mismatch blocks CI the first time it touches state written locally.

**Acceptance.** The `plan` workflow succeeds on every applied stack.

---

### CR-3. Federated domain execution (platform side)

**Objective.** The platform creates each domain's space and delegates the rights to run it. The domain's identity can act inside its own space only.

#### 3.1 What lives where after this change

| Change | Repository | Run by | Approved by |
|---|---|---|---|
| New domain: catalog, storage, base groups, deployment identity, warehouse, administrative unit, delegated rights | Platform | Platform pipeline | Platform team; that domain's team reviews |
| Domain-specific platform settings: warehouse size, budget, App Space, Lakebase, anon flag, admins | Platform: that domain's own file | Platform pipeline | Platform team **and** that domain's team (CODEOWNERS on the file) |
| Tag taxonomy, masks, Sensitive Access Roles | Platform | Platform pipeline | Governance |
| Consumer domain definition | Platform | Platform pipeline | Platform team and the consumer lead |
| Vault definition (sources, schemas) | Platform | Platform pipeline | Platform and vault teams |
| Schemas in the domain catalog (private and product; see D1) | Domain | Domain pipeline | Domain team |
| Publishing, changing and deprecating a product (schema, product group, grants, tags) | Domain | Domain pipeline | Domain team |
| Approving a consumer for a product | Domain | Domain pipeline | Domain owners |
| Tables, pipelines, jobs, column tags | Domain | Domain pipeline | Domain team |
| People in consumer groups | none | Consumer lead, directly in Entra | Consumer lead |

#### 3.2 Changes

**a. One configuration file per domain.**
- Split `config/domains.yaml` into:
  - `config/domains/<domain>.yaml`: one file per domain.
  - `config/vault.yaml`: the vault definition.
  - `config/domain_defaults.yaml`: reserved names, anon schemas, and the platform-owned `admin` schema.
- `modules/naming` reads the directory.
- CODEOWNERS: each domain file is owned by the platform team **and** that domain's team.
- *Why:* GitHub routes approvals per file, so a domain can only review the platform settings that concern it if they sit in their own file.

**b. Product definitions leave the platform repository.**
- Delete `config/products/`. Products are defined in each domain repository (CR-4).
- Remove from `modules/naming`:
  - product groups
  - product nesting
  - product schemas, their grants and tags
  - generated `piq_product` tag values
  - product checks: unique names, consumer cycles, consumers not containing the owner
- Those checks move to the enabler module (per domain) and the central check (k).
- *Why:* product decisions belong to the domain and are executed by it.

**c. Administrative units (stack 20).**
- Create one Entra administrative unit per domain per environment (D4): `au-piq-{env}-{domain}`.
- Assign `sp-piq-{env}-{domain}-deploy` the **Groups Administrator** role **scoped to that unit**.
- Assign deployment identities **Directory Readers**, so they can look up consumer groups by name without reading platform state.
- Only groups the domain creates live in the unit. Platform-managed groups (local roles, writer, SAR, persona, consumer) stay outside it, so the domain cannot change them.
- *Why:* this lets the domain create and manage its own product groups without tenant-wide rights.

**d. Catalog-users group (stacks 20 and 40).**
- Add one platform-created group per domain catalog, `piq-{env}-{domain}-catalog-users`, placed **inside** the domain's administrative unit.
- Stack 40 grants it `USE CATALOG` (no `BROWSE`) on the domain catalog.
- The domain adds each of its product groups to it.
- *Why:* catalog-level grants stay authoritative and platform-owned. If domains added grants at catalog level directly, every platform apply would revoke them. Consumers still never see private schema names.

**e. Delegated rights in Unity Catalog (stack 40).**
- Grant `sp-piq-{env}-{domain}-deploy` on its own catalog: `USE CATALOG`, `BROWSE`, `CREATE SCHEMA`, `MANAGE`.
- The identity owns the schemas it creates, so it can grant on them.
- The platform identity remains the catalog owner.
- *Why:* everything below catalog level becomes the domain's own business, with no rights outside the catalog.

**f. Stop managing schemas inside domain catalogs (stack 40).**
- In domain catalogs, the platform creates only the catalog, its storage chain, bindings, catalog grants, catalog tags and the `admin` schema.
- Private and product schemas, their grants and tag assignments are removed from platform management (migration in section 3).
- Vault, platform, sandbox, consumer prep and anon catalogs are unchanged.

**g. Tag policies (stack 40).**
- Make `piq_product` free-form (no generated value list); the naming standard is enforced by the module and the central check.
- Add deployment identities to the assigners of `piq_layer`, `piq_product`, `piq_product_type` and `piq_product_status`.
- *Why:* the platform no longer knows product names, and the domain must be able to tag its own schemas. Tag *policies* stay with governance.

**h. Register domain-created groups (stack 30).**
- Per decision D3. If option (b): resolve every member group of the domain administrative units in addition to the groups from stack 20, and run stack 30 on a schedule as well as on change.

**i. Per-domain state (stack 10).**
- Create a container `tfstate-{env}-{domain}` in the state storage account.
- Grant only `sp-piq-{env}-{domain}-deploy` **Storage Blob Data Contributor** on it.
- Domain backends use Entra authentication, as the platform stacks do (shared keys are disabled).

**j. Enabler module.**
- Publish `modules/domain` per D2 and version it with tags.
- It takes the domain key, environment and the domain's `products.yaml`, and creates:
  - private schemas with the standard grants (the grant matrix moves here from `access_matrix.yaml`)
  - product schemas `product_{name}`
  - product groups `piq-{env}-product-{name}` inside the domain's unit
  - each product group nested into the catalog-users group
  - consumer nesting, with the current rules:
    - a domain consumer nests its producer, analyst and ai groups in the same environment
    - a consumer domain nests its role groups, prd only
  - `event_log` read for the domain's product groups
  - schema tags
- It validates:
  - product names are unique within the domain and follow the pattern
  - the owner is not listed as a consumer
  - every consumer group exists (the lookup fails otherwise)
- *Why:* the platform provides the standard and the domain runs it. The privilege scope enforces the boundary, so a domain that bypasses the module still cannot act outside its space.

**k. Central checks.**
- Add a scheduled platform workflow and a `prd_platform.governance` view that report:
  - product names duplicated across domains
  - dependency cycles between domains
  - product schemas or groups that break the naming standard
  - product schemas missing `piq_product_status` or a contract (CR-9)
  - groups in administrative units that no product uses
- *Why:* these rules need the whole mesh in view, which no single domain repository has.

**l. Unchanged.**
- Masks and Sensitive Access Roles: catalog-level policies apply to schemas created later by domains.
- Mask exemptions: the writer group already contains the deployment identity.
- Vault grants, warehouses, budgets, observability views.
- Confirm that `governance.products` still lists products when the domain applies the tags.

**Rationale.**
- Domains own the decisions about their data, so they should also run them, from their own repository, with their own identity and delegated rights scoped to their space.
- The platform team keeps control of what spans domains: catalogs, identity, compute, cost, sensitive-data policy and naming.
- Changes that concern only one domain no longer queue behind platform releases.

**Acceptance.**
- In dev, a domain publishes a new product and approves a consumer from its own repository, with **no** platform pull request. The consumer can query the product.
- The domain identity gets `PERMISSION_DENIED` when it tries to create a schema in another domain's catalog, and is refused when it tries to change a group outside its administrative unit.
- After the domain's change, a platform `plan` of stacks 20 and 40 shows **no changes**.
- Masks apply to columns in a schema the domain created.

---

### CR-4. Domain repository template with infrastructure and deployment pipeline

**Objective.** A domain repository deploys its infrastructure and pipelines to dev and prd through CI, with no secrets.

**Finding.** `templates/domain-bundle` has an Asset Bundle but no workflow. Workspace URLs and deployment identity IDs are placeholders hard-coded in `databricks.yml`.

**Change.** Restructure the template:

```
products.yaml              products of this domain and their consumers
contracts/<product>.md     one contract per product (CR-9)
infra/                     Terraform using the enabler module; backend tfstate-{env}-{domain}
databricks.yml, resources/ Asset Bundle: jobs and pipelines
dbt/                       dbt project
.github/workflows/deploy.yml
.github/CODEOWNERS         domain team owns the repository
```

`deploy.yml` has three stages:

1. **Pull request** (GitHub environment `dev`):
   - `terraform fmt -check`, `validate`, `plan` of `infra/` (plan posted on the pull request)
   - `databricks bundle validate -t dev`
   - `dbt parse`
2. **Merge to main** (environment `dev`):
   - `terraform apply` of `infra/`
   - `databricks bundle deploy -t dev`
   - `databricks bundle run dbt_build -t dev` as a smoke test
3. **After dev succeeds** (environment `prd`, required reviewers):
   - `terraform apply` of `infra/`
   - `databricks bundle deploy -t prd`

Requirements:
- Workflow permissions `id-token: write`, `contents: read`.
- Sign in with `azure/login` (OIDC), then set `DATABRICKS_AUTH_TYPE=azure-cli`.
- GitHub environments named **exactly** `dev` and `prd`. Each deployment identity trusts only `repo:<org>/<domain-repo>:environment:<env>` (`modules/naming/main.tf`, service principal subjects). Any other name fails to sign in.
- Values set as variables on each GitHub environment, not in code:
  - `AZURE_CLIENT_ID` (deployment identity), `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
  - `DATABRICKS_HOST`
  - The values come from the outputs of stack 10 (`workspaces`) and stack 20 (`service_principals`).
- Same Terraform version as CR-2.

**Rationale.**
- Domain changes ship through the domain's own pipeline and identity, which is what makes federation real.
- The `dev`/`prd` environment names are the trust boundary for each identity.

**Acceptance.**
- Merging to main deploys infrastructure and pipelines to dev with no stored secrets.
- The prd deploy waits for approval.
- A run from another repository or environment is refused by Entra.

---

### CR-5. Create the domain repositories

**Objective.** Each producer domain in configuration has a working repository.

**Finding.** Configuration names `piq-claims`, `piq-policy-financial` and `piq-profitability`, but none of them exist.

**Change.**
- For each domain:
  - Create the repository from the CR-4 template. The name must match `repo:` in the domain's configuration file.
  - Add the `dev` and `prd` environments with their variables.
  - Turn on branch protection with code-owner review.
  - Move that domain's products from the old `config/products/<domain>.yaml` into its `products.yaml`.
  - Run the migration (section 3).
- Start with one domain as a pilot, then the others.
- Creating repositories is a manual checklist for now. Automating it needs a GitHub App and is out of scope.

**Rationale.** Without the repositories, no domain pipeline exists.

**Acceptance.** Each domain's products are built by its own pipeline in dev and prd, and its `infra/` plan shows no changes.

---

### CR-6. Vault loading repository and pipeline

**Objective.** Source data reaches the raw vault through CI.

**Finding.** The vault loader identity `sp-piq-{env}-vault-loader` trusts the `piq-vault` repository, but no repository, template or loading job exists.

**Change.**
- Create `piq-vault` with an Asset Bundle holding the loader jobs and their metadata.
- The jobs run as the vault loader identity on `piq-vault-load`.
- Use the CR-4 workflow without the `infra/` stage. Vault schemas stay platform-managed because the vault is shared.

**Rationale.** The vault is the source for every domain. Loading it by hand breaks the rule that only the loader writes it.

**Acceptance.** CI loads landing, staging and raw vault tables in dev and prd as the loader identity.

---

### CR-7. Anonymization job for `prd_{domain}_anon`

**Objective.** Dev pipelines read anonymized production data produced by CI.

**Finding.** Documentation says the domain repository writes `prd_{domain}_anon.data` with an anonymization job reviewed by governance. No such job exists. The catalog, the dev binding and the grants (`anon: { writer: RWC, dev_readers: R }`) already exist in the platform.

**Change.**
- Add an anonymization job to the claims repository, deployed only to the `prd` target, writing irreversibly anonymized data to `prd_claims_anon.data`.
- Governance co-owns the job's path in that repository's CODEOWNERS.

**Rationale.** It is the only permitted path for production data to reach dev. Masks are not anonymization.

**Acceptance.** Dev reads `prd_claims_anon.data`, and governance has approved the job.

---

### CR-8. Apply platform changes automatically after approval

**Objective.** A merged platform change is applied without anyone choosing stacks by hand.

**Finding.**
- `apply.yml` runs only on manual dispatch, one stack per run.
- The operator picks the stacks from the table in `docs/OPERATIONS.md`.
- Pull requests created from access requests end with "apply the stacks listed in docs/OPERATIONS.md".
- This step can be missed or done out of order.

**Change.**
- Trigger `apply.yml` on push to `main`; keep manual dispatch.
- In one job, for each stack in order 10, 20, 30, 40, 50, 55, 60, 70:
  - run `terraform plan -detailed-exitcode`
  - apply only when the exit code is 2 (changes present)
- One approval on the `platform` environment covers the run. Keep the concurrency lock.
- Update the access-request pull request text and `OPERATIONS.md`.

**Rationale.** Stack order and selection are mechanical; a pipeline does them more reliably than a person.

**Acceptance.** Merging a platform change makes it live after a single approval, and stacks with no changes are skipped.

---

### CR-9. Data product contracts

**Objective.** Every published product has a contract that its consumers can rely on.

**Finding.** Products reference `docs/contracts/<name>.md`, but no contract files exist.

**Change.**
- Contracts live in the domain repository at `contracts/<product>.md`, from a template in CR-4. The template covers:
  - purpose and owner
  - schema with column descriptions and sensitivity tags
  - grain
  - refresh schedule and latency
  - quality checks
  - service level
  - change and deprecation policy
- The domain pipeline fails if a product with status `published` has no contract.

**Rationale.** A product without a contract cannot be relied on, and its consumers can't tell what a change will break.

**Acceptance.** Every published product has a contract, and the central check (CR-3 k) reports none missing.

---

### CR-10. Remove write rights from people in prd domain admin groups

**Objective.** People never write prd data.

**Finding.**
- `access_matrix.yaml` grants `dbadmin: [ALL_PRIVILEGES, MANAGE]` on every domain catalog in every environment. In prd, that includes `MODIFY` for the people in `piq-prd-{domain}-dbadmin`.
- `service_principal_only_in_prd` covers only `producer`.

**Change.**
- In prd, give the dbadmin group `USE CATALOG` and `BROWSE`, plus read through the local roles.
- Delegated rights in prd belong only to the deployment identity (CR-3 e).
- Dev is unchanged.
- Add a validator rule so this cannot regress.

**Rationale.** People change prd only through the pipeline.

**Acceptance.** A prd dbadmin member gets `PERMISSION_DENIED` on `INSERT` into any prd domain table.

---

## 6. Documentation updates

| Document | Update |
|---|---|
| README | Layout (`config/domains/`, no `config/products/`); rule 8 (domain decisions are made **and run** in domain repositories); rule 7 if D2 is (b) |
| ARCHITECTURE | Sections 2, 3, 5, 6: federation boundary, administrative units, catalog-users group, delegated rights |
| OPERATIONS | Split the procedure table into platform repository and domain repository procedures; remove "apply stacks" columns after CR-8 |
| CONFIGURATION | New file layout; remove products; add the domain `products.yaml` reference |
| CONCEPTS | Stacks 20 and 40 sections; a new section on domain repositories and delegation |
| DECISIONS | New ADR-022 *Federated domain execution*. Amend ADR-020 (product files move to domain repositories), ADR-015 (isolation through the catalog-users group), ADR-005 (CR-10) |
| RUNBOOK | Terraform version (CR-2); bootstrap remote state (CR-1); new phase for creating domain repositories |
| Template READMEs | CR-4 structure and workflow |

---

## 7. Implementation order

1. CR-1 and CR-2 (now).
2. CR-10 (independent, small).
3. Decisions D1–D4.
4. CR-3 platform changes and CR-4 template and module, then run section 3.1.
5. CR-5 with one pilot domain: migration (section 3), then the CR-3 acceptance tests in dev, then prd.
6. CR-5 for the remaining domains, and CR-9.
7. CR-8.
8. CR-6 and CR-7.

## 8. Overall acceptance

- No state, keys or secrets in any repository. CI uses OIDC only.
- Every domain change ships from that domain's repository through its own pipeline and identity. Every platform change ships from the platform repository after one approval.
- No domain identity can act outside its catalog or its administrative unit.
- After all changes, `plan` is clean in every platform stack and every domain repository.
- `make test`, `make plan-test` and the `validate` workflow pass, with tests updated for the new configuration layout.
