# =============================================================================
# 40-unity-catalog - governed tag taxonomy + every Unity Catalog object.
#
# Prerequisite (RUNBOOK Phase 4): the piq-metastore-admins group, which contains
# sp-<prefix>-terraform, is the metastore admin. That is what allows Terraform
# to create storage credentials, external locations and catalogs.
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

  by_env = { for env in module.naming.env_keys : env => {
    catalogs = { for k, c in module.naming.catalogs : k => c if c.env == env }
    schemas  = { for k, s in module.naming.schemas : k => s if s.env == env }
    volumes  = { for k, v in module.naming.volumes : k => v if v.env == env }
  } }
}

# -----------------------------------------------------------------------------
# Governed tags (tag policies). Account-wide objects, created through the dev
# workspace because the API is workspace-scoped.
# -----------------------------------------------------------------------------
resource "databricks_tag_policy" "this" {
  provider    = databricks.dev
  for_each    = module.naming.governed_tags.tags
  tag_key     = each.key
  description = each.value.description
  values      = [for v in each.value.values : { name = v }]
}

# Who may APPLY each tag. Tagging is a security boundary: `pii` decides masking.
resource "databricks_access_control_rule_set" "tag" {
  provider = databricks.account
  for_each = module.naming.governed_tags.tags
  name     = "accounts/${local.account_id}/tagPolicies/${databricks_tag_policy.this[each.key].id}/ruleSets/default"

  # metastore-admins contains sp-<prefix>-terraform; keep it a manager so that
  # Terraform can still assign tags after this authoritative rule set applies.
  grant_rules {
    principals = [
      "groups/${module.naming.platform_groups["governance-admins"].name}",
      "groups/${module.naming.platform_groups["metastore-admins"].name}",
    ]
    role = "roles/tagPolicy.manager"
  }
  grant_rules {
    principals = [for g in module.naming.tag_assigner_groups[each.key] : "groups/${g}"]
    role       = "roles/tagPolicy.assigner"
  }
}

# -----------------------------------------------------------------------------
# Unity Catalog objects per environment (one module call per workspace provider)
# -----------------------------------------------------------------------------
module "uc_dev" {
  source    = "../../modules/uc_environment"
  providers = { databricks = databricks.dev }

  env                  = "dev"
  prefix               = module.naming.prefix
  workspace_id         = local.ws["dev"].workspace_id
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
  prefix               = module.naming.prefix
  workspace_id         = local.ws["prd"].workspace_id
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
