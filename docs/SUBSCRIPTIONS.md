# Azure subscriptions: one for everything today, one per environment later

An Azure **subscription** is a billing and permission boundary. Everything in Azure lives in
exactly one. This page describes how the platform uses subscriptions now, what it would look
like to give each environment its own, and how to get from one to the other.

**Status.** The current model (one subscription) is what the code does. The per-environment model
is **not built**: nothing in the repo reads a per-environment subscription yet. Nothing here has been
tried against real Azure.

---

## 1. The current model: one subscription for everything

```
config/platform.yaml
  azure:
    subscription_id: b821d55b-...        <- the only subscription the platform knows
```

```
 ONE SUBSCRIPTION  (b821d55b-...)
 ├─ rg-piq-tfstate      state storage account        (bootstrap)
 ├─ rg-piq-dev          vnet, workspace, storage, Key Vault, access connector   (bootstrap makes the group, stack 10 fills it)
 └─ rg-piq-prd          the same for prd
```

Where the subscription id is read:

| Place | What it does with it |
|---|---|
| `config/platform.yaml` `azure.subscription_id` | The single source |
| `bootstrap/main.tf` provider `azurerm` | Creates the state storage, the per-environment resource groups and the role assignments, all in that subscription |
| `bootstrap/main.tf` role assignments | The shared identity `sp-piq-terraform` gets Contributor and RBAC Administrator on the **whole subscription**; each `sp-piq-terraform-<env>` gets them on **its resource group only** |
| `stacks/10-foundation/providers.tf` | Builds every Azure resource of an environment in that subscription |
| GitHub variable `AZURE_SUBSCRIPTION_ID` | Used by `azure/login` in every workflow. It is set per GitHub environment, but today every environment holds the same value |

What the single subscription does and does not separate:

| | Separated today? |
|---|---|
| Who can change what, inside Azure | **Partly.** Each environment's identity is limited to its resource group, so a dev run cannot create or delete prd Azure resources |
| Billing and cost reports | No. One bill; you split it by resource group or tag |
| Quotas (cores, IP addresses, workspaces) | No. dev and prd draw from the same limits |
| Azure Policy and subscription-level rules | No. The same policies apply to both |
| The shared identity's reach | No. `sp-piq-terraform` can touch the whole subscription |
| Databricks, Entra | Not an Azure-subscription matter. Entra and the Databricks account are tenant and account wide in either model |

This is a fine setup for a platform with one team and two environments. It is the simplest to run.

---

## 2. The per-environment model

Each environment may name its own subscription. If it does not, it uses `azure.subscription_id`.

```
config/platform.yaml
  azure:
    subscription_id: b821d55b-...                 <- default, and where the state storage lives
  environments:
    dev:
      subscription_id: b821d55b-...               <- optional; omit to use the default
    prd:
      subscription_id: 7c0e1a22-...               <- prd in its own subscription
```

```
 SUBSCRIPTION A (default)               SUBSCRIPTION B (prd only)
 ├─ rg-piq-tfstate  state storage       └─ rg-piq-prd   vnet, workspace, storage, Key Vault
 └─ rg-piq-dev      dev resources
```

What you gain:

- **A hard wall for production.** prd has its own permissions, so even a mistake in the dev
  identity's rights cannot reach prd Azure resources. Azure Policy and access reviews can be
  stricter on the prod subscription.
- **Separate billing and quotas.** A dev experiment cannot use up prd's core quota.
- **A smaller shared identity.** `sp-piq-terraform` no longer needs subscription-wide rights.

What it does not change:

- Entra (users, groups) and the Databricks account are the same tenant and account. A dev
  identity is still not technically blocked from prd *groups* or the prd *Databricks workspace*
  by Azure rights. Only Entra administrative units (CR-001) address that.
- Terraform state stays in one storage account in the default subscription.

What it costs:

- More setup: each subscription needs the Azure resource providers registered
  (`Microsoft.Databricks`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.KeyVault`,
  `Microsoft.ManagedIdentity`), and its own quotas checked.
- `bootstrap/` stops being configuration-only for new environments (see 3, item 2).

---

## 3. What would have to change in the code

Small items first. None of these is built.

1. **`config/platform.yaml` and the validator.** Add an optional `subscription_id` per environment
   (checked as a GUID). The default stays `azure.subscription_id`.
2. **`bootstrap/`, the hard part.** Its single `azurerm` provider points at one subscription. The
   per-environment resource group and the role assignments must be created in that environment's
   subscription, and Terraform cannot create providers from a list. Two ways:
   - **(a)** write one provider block per environment in `bootstrap/` by hand. Adding an
     environment then needs a code edit.
   - **(b)** (recommended) split bootstrap in two. `bootstrap/` keeps the state storage and the
     shared identity. A new `bootstrap-env/` is run once per environment with
     `-var environment=<env>`, takes the subscription from config, and has its own state. Adding an
     environment stays configuration plus one run.
3. **`stacks/10-foundation/providers.tf`.** Read the subscription for `var.environment`
   instead of the default. Easy, because every stack 10 run is already for one environment.
4. **Role assignments.** Each `sp-piq-terraform-<env>` needs Contributor and RBAC Administrator on
   its resource group in **its** subscription, and read-write on the state storage in the
   **default** one. Cross-subscription role assignments are allowed in Azure. Reduce
   `sp-piq-terraform` to what shared work needs (state storage and Graph rights), dropping its
   subscription-wide Contributor.
5. **Post-apply checks.** `stacks/10-foundation/checks.py` calls `az storage account show` without a
   subscription; add `--subscription <the environment's>`.
6. **Pipelines.** No workflow change. `AZURE_SUBSCRIPTION_ID` is already a variable of each GitHub
   environment: give `prd` and `prd-plan` the prd subscription id.
7. **Docs.** RUNBOOK Phase 1 (register providers per subscription), Phase 2 (the extra bootstrap
   run per environment), and CONFIGURATION.

To check before relying on it (not tested here): that Azure Databricks workspaces in two
subscriptions attach to the same Unity Catalog metastore in the same region; that your
tenant policy allows the role assignments across subscriptions; and each subscription's
quota for the workspace SKU and networking you use.

---

## 4. Path from today to per-environment subscriptions

Because every environment has its own Terraform state, you can convert **one environment at a
time**. Convert prd first; dev can stay where it is.

**Moving existing resources between subscriptions is not a path to rely on.** Azure can move some
resource types between subscriptions, but a VNet-injected Databricks workspace with Unity Catalog
storage bound to it is not a good candidate (confirm in Microsoft's current "move resources"
support table before deciding otherwise). Plan on **rebuilding** the environment in the new
subscription. With no data yet, that is cheap.

Steps, for example for prd:

1. **Decide.** You have a reason: a separate prod billing owner, stricter policy on production, or
   separate quotas. Without one, stay on one subscription.
2. **Prepare the new subscription.** Create it, register the resource providers (section 2),
   check quotas in the region, and give yourself Owner on it.
3. **Build the code change** (section 3), with tests: the validator accepts the new field; a plan
   of stack 10 for prd shows the new subscription id in its resource ids.
4. **Tear down the old prd.** Destroy prd's targets in reverse order (the RUNBOOK deploy order, backwards,
   for `--env prd` only). Dev is not affected because its states are separate. Keep the
   shared scopes, which hold no prd resources.
5. **Set the new subscription in config.** `environments.prd.subscription_id`. If prd's Key Vault
   name was purge-protected (it is, for the prod tier), change `unique_suffix` or wait out the
   90 days.
6. **Create prd's resource group and identity** in the new subscription (`bootstrap-env/` for prd,
   or the bootstrap edit if you chose option (a)). Update the GitHub variable
   `AZURE_SUBSCRIPTION_ID` on the `prd` and `prd-plan` GitHub environments, and
   `AZURE_CLIENT_ID` for the new identity.
7. **Rebuild prd** in the normal deploy order, from a release that has passed in dev.
   The promotion gate still applies.
8. **Re-run the shared scopes that name prd.** The usual "add an environment" rule: `20 shared`
   (adds the new identity to `piq-metastore-admins`) and `40 shared` (tag assigners).
9. **Verify.** `python3 scripts/plan_all.py --env prd` shows no changes; the new workspace is
   assigned to the metastore; the old subscription holds no prd resources.

Converting dev later repeats the same steps with `dev`.

---

## 5. When to do it

| Situation | Recommendation |
|---|---|
| One team, two environments, no external audit | Stay on one subscription |
| A reviewer or auditor asks for separate production access | Convert prd first |
| Prod and nonprod have different billing owners or cost centres | Convert prd |
| You expect many environments (qa, uat, dev2) | Keep nonprod environments together in one subscription and give only the prod environment its own |

The design leaves the option open: the environment list is configuration, so adding the field later
changes nothing else.
