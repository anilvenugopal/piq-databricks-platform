# =============================================================================
# 60-governance - masking functions + ABAC column-mask policies + data
# classification.
#
# Separation of duties: changes to this stack and to config/governed_tags.yaml
# require review by the governance-admins team (.github/CODEOWNERS).
#
# One policy per (data catalog x pii value):
#   ON CATALOG <env>_<domain>  COLUMN MASK <env>_platform.governance.mask_<type>
#   TO `account users`  EXCEPT <producer, admin, dbadmin groups of that domain>
#   MATCH COLUMNS has_tag_value('pii', '<type>')
# =============================================================================

module "naming" {
  source     = "../../modules/naming"
  config_dir = "${path.root}/../../config"
}

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "10-foundation.tfstate" })
}

data "terraform_remote_state" "workspace" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "50-workspace.tfstate" })
}

variable "enable_data_classification" {
  description = "Scan data catalogs for sensitive columns (suggests/auto-applies class.* system tags)"
  type        = bool
  default     = true
}

locals {
  ws         = data.terraform_remote_state.foundation.outputs.workspaces
  warehouses = data.terraform_remote_state.workspace.outputs.warehouse_ids
  masks      = module.naming.governed_tags.masks
  unmasked   = module.naming.matrix.unmasked_roles
  sql_file   = "${path.root}/../../sql/governance/masking_functions.sql"

  data_catalogs = { for k, c in module.naming.catalogs : k => c if c.kind == "data" }

  policies = { for t in setproduct(keys(local.data_catalogs), keys(local.masks)) :
    "${t[0]}|${t[1]}" => {
      catalog_key = t[0]
      catalog     = local.data_catalogs[t[0]].name
      env         = local.data_catalogs[t[0]].env
      domain      = local.data_catalogs[t[0]].domain
      pii         = t[1]
      function    = "${local.data_catalogs[t[0]].env}_platform.governance.${local.masks[t[1]].function}"
      except = [for role in local.unmasked :
        module.naming.functional_groups["${local.data_catalogs[t[0]].env}-${local.data_catalogs[t[0]].domain}-${role}"].name
      ]
    }
  }
}

# Masking functions are SQL objects; Terraform runs the SQL file through the
# Statement Execution API whenever the file changes.
resource "terraform_data" "masking_functions" {
  for_each         = toset(module.naming.env_keys)
  triggers_replace = [filemd5(local.sql_file), local.warehouses[each.key]["etl"]]

  provisioner "local-exec" {
    command = join(" ", [
      "python3 ${path.root}/../../scripts/run_sql.py",
      "--host ${local.ws[each.key].url}",
      "--warehouse-id ${local.warehouses[each.key]["etl"]}",
      "--file ${local.sql_file}",
      "--set catalog=${each.key}_platform",
    ])
  }
}

resource "databricks_policy_info" "dev_mask" {
  provider              = databricks.dev
  for_each              = { for k, p in local.policies : k => p if p.env == "dev" }
  name                  = "mask_${each.value.pii}"
  on_securable_type     = "CATALOG"
  on_securable_fullname = each.value.catalog
  policy_type           = "POLICY_TYPE_COLUMN_MASK"
  for_securable_type    = "TABLE"
  to_principals         = ["account users"]
  except_principals     = each.value.except
  comment               = "Mask columns tagged pii=${each.value.pii}. Managed by terraform."
  match_columns = [
    { condition = "has_tag_value('pii', '${each.value.pii}')", alias = "c" },
  ]
  column_mask = {
    function_name = each.value.function
    on_column     = "c"
  }
  depends_on = [terraform_data.masking_functions]
}

resource "databricks_policy_info" "prd_mask" {
  provider              = databricks.prd
  for_each              = { for k, p in local.policies : k => p if p.env == "prd" }
  name                  = "mask_${each.value.pii}"
  on_securable_type     = "CATALOG"
  on_securable_fullname = each.value.catalog
  policy_type           = "POLICY_TYPE_COLUMN_MASK"
  for_securable_type    = "TABLE"
  to_principals         = ["account users"]
  except_principals     = each.value.except
  comment               = "Mask columns tagged pii=${each.value.pii}. Managed by terraform."
  match_columns = [
    { condition = "has_tag_value('pii', '${each.value.pii}')", alias = "c" },
  ]
  column_mask = {
    function_name = each.value.function
    on_column     = "c"
  }
  depends_on = [terraform_data.masking_functions]
}

# Data classification scans catalogs and proposes (or applies) class.* system
# tags. Review its findings, then apply the governed `pii` tag your policies use.
resource "databricks_data_classification_catalog_config" "dev" {
  provider = databricks.dev
  for_each = var.enable_data_classification ? { for k, c in local.data_catalogs : k => c if c.env == "dev" } : {}
  parent   = "catalogs/${each.value.name}"
}

resource "databricks_data_classification_catalog_config" "prd" {
  provider = databricks.prd
  for_each = var.enable_data_classification ? { for k, c in local.data_catalogs : k => c if c.env == "prd" } : {}
  parent   = "catalogs/${each.value.name}"
}

output "policies" {
  value = sort(keys(local.policies))
}
