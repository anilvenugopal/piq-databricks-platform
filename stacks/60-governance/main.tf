# =============================================================================
# 60-governance - masking functions, ABAC column-mask policies, data
# classification.
#
# One policy per (domain | vault | consumer prep catalog) x mask, for example:
#   ON CATALOG prd_claims  COLUMN MASK prd_platform.governance.mask_ssn
#   TO `account users`  EXCEPT <SAR groups unlocking ssn>, <catalog writers>
#   MATCH COLUMNS has_tag_value('pii', 'ssn')
# Producers and analysts build with masked values; only SAR members and the
# identities that write the data see clear values.
#
# Separation of duties: changes here, in config/sars.yaml and in
# config/governed_tags.yaml need governance review (.github/CODEOWNERS).
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
  description = "Scan domain and vault catalogs for sensitive columns (proposes class.* system tags)"
  type        = bool
  default     = true
}

locals {
  ws         = data.terraform_remote_state.foundation.outputs.workspaces
  warehouses = data.terraform_remote_state.workspace.outputs.warehouse_ids
  sql_file   = "${path.root}/../../sql/governance/masking_functions.sql"
  policies   = module.naming.abac_policies

  classified = { for k, c in module.naming.catalogs : k => c if contains(["domain", "vault"], c.kind) }
}

# Masking functions are SQL objects; Terraform runs the SQL file through the
# Statement Execution API on the shared warehouse whenever the file changes.
resource "terraform_data" "masking_functions" {
  for_each         = toset(module.naming.env_keys)
  triggers_replace = [filemd5(local.sql_file), local.warehouses[each.key]["piq-shared"]]

  provisioner "local-exec" {
    command = join(" ", [
      "python3 ${path.root}/../../scripts/run_sql.py",
      "--host ${local.ws[each.key].url}",
      "--warehouse-id ${local.warehouses[each.key]["piq-shared"]}",
      "--file ${local.sql_file}",
      "--set catalog=${each.key}_platform",
    ])
  }
}

resource "databricks_policy_info" "dev" {
  provider              = databricks.dev
  for_each              = { for k, p in local.policies : k => p if p.env == "dev" }
  name                  = each.value.name
  on_securable_type     = "CATALOG"
  on_securable_fullname = each.value.catalog
  policy_type           = "POLICY_TYPE_COLUMN_MASK"
  for_securable_type    = "TABLE"
  to_principals         = ["account users"]
  except_principals     = each.value.except
  comment               = "Mask columns where ${each.value.condition}. Managed by terraform."
  match_columns         = [{ condition = each.value.condition, alias = "c" }]
  column_mask = {
    function_name = each.value.function
    on_column     = "c"
  }
  depends_on = [terraform_data.masking_functions]
}

resource "databricks_policy_info" "prd" {
  provider              = databricks.prd
  for_each              = { for k, p in local.policies : k => p if p.env == "prd" }
  name                  = each.value.name
  on_securable_type     = "CATALOG"
  on_securable_fullname = each.value.catalog
  policy_type           = "POLICY_TYPE_COLUMN_MASK"
  for_securable_type    = "TABLE"
  to_principals         = ["account users"]
  except_principals     = each.value.except
  comment               = "Mask columns where ${each.value.condition}. Managed by terraform."
  match_columns         = [{ condition = each.value.condition, alias = "c" }]
  column_mask = {
    function_name = each.value.function
    on_column     = "c"
  }
  depends_on = [terraform_data.masking_functions]
}

# Data classification proposes class.* system tags. Review its findings, then
# apply the governed pii / sensitive_metric tags that the policies match.
resource "databricks_data_classification_catalog_config" "dev" {
  provider = databricks.dev
  for_each = var.enable_data_classification ? { for k, c in local.classified : k => c if c.env == "dev" } : {}
  parent   = "catalogs/${each.value.name}"
}

resource "databricks_data_classification_catalog_config" "prd" {
  provider = databricks.prd
  for_each = var.enable_data_classification ? { for k, c in local.classified : k => c if c.env == "prd" } : {}
  parent   = "catalogs/${each.value.name}"
}

output "policies" {
  value = sort(keys(local.policies))
}
