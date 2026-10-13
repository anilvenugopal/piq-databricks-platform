# Configuration reference

All behaviour comes from `config/`. `modules/naming` reads every file; each stack
uses the parts it needs. Validate after any edit: `python3 scripts/validate_config.py`.

| File | Owns | Used by stacks |
|---|---|---|
| `platform.yaml` | prefix, suffix, Azure IDs, region, state backend, GitHub org, per-env network, IP lists, egress | all |
| `domains.yaml` | domains, standard schemas and volumes, reserved names | 10, 20, 30, 40, 55, 60 |
| `access_matrix.yaml` | roles, privilege bundles, LAYER x ROLE matrix, SP-only roles, unmasked roles | 20, 40, 60 |
| `workspace_objects.yaml` | warehouses, compute policies, vector search and their ACLs | 50, 55 |
| `personas.yaml` | personas (nesting + members) and platform groups (with workspace access) | 20, 30, 40 |
| `service_principals.yaml` | SPs, their group memberships, workspaces, GitHub OIDC subjects | 20, 30 |
| `governed_tags.yaml` | tag keys, allowed values, assigners; PII mask mapping | 40, 60 |
| `cost.yaml` | budget amounts and thresholds; usage policies on/off | 30 |
| `sandbox_users.yaml` | dev personal sandboxes | 20, 30, 40 |
| `experiments.yaml` | approved prd experiments | 20, 30, 40 |
| `test_users.yaml` | training-only Entra users | 20 |

## Key fields

**platform.yaml**
- `prefix` (2–5 lowercase letters): first segment of every name.
- `unique_suffix` (3–6 alphanumerics): appended to storage and Key Vault names.
- `environments.<env>.network.nat_gateway`: classic-compute internet egress.
- `environments.<env>.ip_access_list`: empty disables IP enforcement.
- `environments.<env>.serverless_egress.restriction_mode`: `FULL_ACCESS` or
  `RESTRICTED_ACCESS`; `enforcement_mode`: `DRY_RUN` or `ENFORCED`.

**access_matrix.yaml**
- `matrix.<schema>.<role>: <bundle>`; a missing role means no grant.
- `service_principal_only_in_prd`: roles humans may never hold in prd.
- `unmasked_roles`: exempt from ABAC masks in their own env/domain.

**personas.yaml**
- `member_of` entries: `"<env>:<domain|*>:<role>"` or a platform group key.
- `platform_groups.<key>.workspaces`: `{ dev: USER|ADMIN, prd: USER|ADMIN }`.

**governed_tags.yaml**
- `assigners`: platform group keys, or `role:<role>` meaning that role's groups in
  every env and domain.
- `masks.<pii value>.function`: name of the function in `{env}_platform.governance`.

## Derived names

| Thing | Pattern | Example |
|---|---|---|
| Resource group | `rg-{prefix}-{env}` | `rg-piq-dev` |
| Workspace | `dbw-{prefix}-{env}` | `dbw-piq-prd` |
| Storage account | `st{prefix}{env}lake{suffix}` | `stpiqdevlakea1b2` |
| Access connector | `ac-{prefix}-{env}` | `ac-piq-dev` |
| Catalog | `{env}_{domain}` | `prd_claims` |
| Functional group | `{prefix}-{env}-{domain}-{role}` | `piq-dev-policy-analyst` |
| Persona group | `{prefix}-persona-{name}` | `piq-persona-data-engineer` |
| Service principal | `sp-{prefix}-{name}` | `sp-piq-prd-deploy` |
| Warehouse | `{prefix}-{env}-{name}` | `piq-dev-bi` |
| Usage policy | `{prefix}-{env}-{domain}` | `piq-prd-claims` |
| Sandbox schema | `dev_sandbox.u_{localpart}` | `dev_sandbox.u_jane_smith` |
| Experiment schema | `prd_sandbox.exp_{name}` | `prd_sandbox.exp_loss_ratio_model_v2` |
