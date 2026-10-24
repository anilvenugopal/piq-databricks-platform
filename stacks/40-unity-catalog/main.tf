# =============================================================================
# 40-unity-catalog - governed tag taxonomy and every Unity Catalog object:
# vault, domain (private + product schemas), consumer prep, anonymized,
# platform and sandbox catalogs, with grants, bindings and tags.
#
# Prerequisite (RUNBOOK Phase 4): piq-metastore-admins, which contains
# sp-<prefix>-terraform, is the metastore admin.
#
# One run owns one scope (see util/scope.py):
#   shared         the governed tag taxonomy (one per account)
#   env            the environment's storage credential, vault/platform/sandbox/consumer catalogs
#   domain:<name>  that domain's catalog, schemas, volumes, grants, tags (and its anonymized catalog)
# State: 40-unity-catalog/shared.tfstate or 40-unity-catalog/<env>/{env,domain-<name>}.tfstate.
# Run order per environment: env first (it creates the credential), then each domain.
# =============================================================================

variable "environment" {
  description = "Environment of this run; unset for scope shared"
  type        = string
  default     = null
}

variable "scope" {
  description = "shared | env | domain:<name>"
  type        = string
  validation {
    condition     = contains(["shared", "env"], var.scope) || startswith(var.scope, "domain:")
    error_message = "40-unity-catalog supports scopes shared, env and domain:<name>."
  }
}

module "naming" {
  source      = "../../modules/naming"
  config_dir  = "${path.root}/../../config"
  environment = var.environment
  scope       = var.scope
}

locals {
  # The tag taxonomy is account-wide but its API is workspace-scoped, so the shared scope
  # calls through the first nonprod environment's workspace.
  home_env = var.scope == "shared" ? module.naming.nonprod_envs[0] : var.environment

  # Other environments whose workspace gets a read-only binding of a catalog in this run.
  readonly_envs = toset(distinct(flatten([for c in values(module.naming.catalogs) : c.readonly_envs])))
}

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "10-foundation/${local.home_env}/env.tfstate" })
}

data "terraform_remote_state" "foundation_other" {
  for_each = local.readonly_envs
  backend  = "azurerm"
  config   = merge(module.naming.state_backend, { key = "10-foundation/${each.key}/env.tfstate" })
}

locals {
  account_id = module.naming.platform.databricks.account_id
  ws         = data.terraform_remote_state.foundation.outputs.workspaces[local.home_env]
  storage    = data.terraform_remote_state.foundation.outputs.storage[local.home_env]
  connector  = data.terraform_remote_state.foundation.outputs.access_connectors[local.home_env]
  ws_ids = merge(
    { (local.home_env) = local.ws.workspace_id },
    { for e, st in data.terraform_remote_state.foundation_other : e => st.outputs.workspaces[e].workspace_id },
  )
  pg = module.naming.platform_group_names
}

# -----------------------------------------------------------------------------
# Governed tags (tag policies). Account-wide objects, so they belong to the shared
# scope (module.naming.governed_tags is empty in every other scope). Created
# through a workspace because the API is workspace-scoped. Generated values
# (domains, products, sources) come from config.
# -----------------------------------------------------------------------------
resource "databricks_tag_policy" "this" {
  for_each    = module.naming.governed_tags
  tag_key     = each.key
  description = each.value.description
  values      = [for v in each.value.values : { name = v }]
}

# Who may apply each tag. Tagging is a security boundary: pii and
# sensitive_metric decide masking. metastore-admins (which holds the Terraform
# SP) stays a manager so Terraform can keep assigning tags.
resource "databricks_access_control_rule_set" "tag" {
  provider = databricks.account
  for_each = module.naming.governed_tags
  name     = "accounts/${local.account_id}/tagPolicies/${databricks_tag_policy.this[each.key].id}/ruleSets/default"

  grant_rules {
    principals = ["groups/${local.pg["mesh-governance"]}", "groups/${local.pg["metastore-admins"]}"]
    role       = "roles/tagPolicy.manager"
  }
  grant_rules {
    principals = [for g in each.value.assigners : "groups/${g}"]
    role       = "roles/tagPolicy.assigner"
  }
}

# -----------------------------------------------------------------------------
# Unity Catalog objects of this run's environment. The shared scope has none.
# -----------------------------------------------------------------------------
module "uc" {
  count     = var.scope == "shared" ? 0 : 1
  source    = "../../modules/uc_environment"
  providers = { databricks = databricks }

  env                  = var.environment
  workspace_id         = local.ws.workspace_id
  workspace_ids        = local.ws_ids
  create_credential    = var.scope == "env"
  access_connector_id  = local.connector
  storage_account_name = local.storage.name
  catalogs             = module.naming.catalogs
  catalog_grants       = module.naming.catalog_grants
  schemas              = module.naming.schemas
  volumes              = module.naming.volumes

  depends_on = [databricks_tag_policy.this]
}

output "catalogs" {
  value = var.scope == "shared" ? {} : module.uc[0].catalog_names
}
