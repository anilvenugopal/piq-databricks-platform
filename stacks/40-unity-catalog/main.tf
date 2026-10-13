# =============================================================================
# 40-unity-catalog - governed tag taxonomy and every Unity Catalog object:
# vault, domain (private + product schemas), consumer prep, anonymized,
# platform and sandbox catalogs, with grants, bindings and tags.
#
# Prerequisite (RUNBOOK Phase 4): piq-metastore-admins, which contains
# sp-<prefix>-terraform, is the metastore admin.
# =============================================================================

module "naming" {
  source     = "../../modules/naming"
  config_dir = "${path.root}/../../config"
}

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "10-foundation.tfstate" })
}

locals {
  account_id = module.naming.platform.databricks.account_id
  ws         = data.terraform_remote_state.foundation.outputs.workspaces
  storage    = data.terraform_remote_state.foundation.outputs.storage
  connectors = data.terraform_remote_state.foundation.outputs.access_connectors
  ws_ids     = { for env, w in local.ws : env => w.workspace_id }
  pg         = module.naming.platform_group_names

  by_env = { for env in module.naming.env_keys : env => {
    catalogs = { for k, c in module.naming.catalogs : k => c if c.env == env }
    schemas  = { for k, s in module.naming.schemas : k => s if s.env == env }
    volumes  = { for k, v in module.naming.volumes : k => v if v.env == env }
  } }
}

# -----------------------------------------------------------------------------
# Governed tags (tag policies). Account-wide objects, created through the dev
# workspace because the API is workspace-scoped. Generated values (domains,
# products, sources) come from config.
# -----------------------------------------------------------------------------
resource "databricks_tag_policy" "this" {
  provider    = databricks.dev
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
# Unity Catalog objects per environment
# -----------------------------------------------------------------------------
module "uc_dev" {
  source    = "../../modules/uc_environment"
  providers = { databricks = databricks.dev }

  env                  = "dev"
  workspace_id         = local.ws_ids["dev"]
  workspace_ids        = local.ws_ids
  access_connector_id  = local.connectors["dev"]
  storage_account_name = local.storage["dev"].name
  catalogs             = local.by_env["dev"].catalogs
  catalog_grants       = module.naming.catalog_grants
  schemas              = local.by_env["dev"].schemas
  volumes              = local.by_env["dev"].volumes

  depends_on = [databricks_tag_policy.this]
}

module "uc_prd" {
  source    = "../../modules/uc_environment"
  providers = { databricks = databricks.prd }

  env                  = "prd"
  workspace_id         = local.ws_ids["prd"]
  workspace_ids        = local.ws_ids
  access_connector_id  = local.connectors["prd"]
  storage_account_name = local.storage["prd"].name
  catalogs             = local.by_env["prd"].catalogs
  catalog_grants       = module.naming.catalog_grants
  schemas              = local.by_env["prd"].schemas
  volumes              = local.by_env["prd"].volumes

  depends_on = [databricks_tag_policy.this]
}

output "catalogs" {
  value = merge(module.uc_dev.catalog_names, module.uc_prd.catalog_names)
}
