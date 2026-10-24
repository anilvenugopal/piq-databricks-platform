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
#
# One run owns one scope (see util/scope.py):
#   env            the environment's masking functions (SQL in <env>_platform.governance),
#                  and the policies and classification of its vault/consumer catalogs
#   domain:<name>  the policies and classification of that domain's catalog
# State: 60-governance/<env>/{env,domain-<name>}.tfstate. Run order per environment:
# env first (the functions the policies call), then each domain.
# =============================================================================

variable "environment" {
  description = "Environment to deploy (a key of environments in config/platform.yaml)"
  type        = string
}

variable "scope" {
  description = "env | domain:<name>"
  type        = string
  validation {
    condition     = var.scope == "env" || startswith(var.scope, "domain:")
    error_message = "60-governance supports scopes env and domain:<name>."
  }
}

module "naming" {
  source      = "../../modules/naming"
  config_dir  = "${path.root}/../../config"
  environment = var.environment
  scope       = var.scope
}

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "10-foundation/${var.environment}/env.tfstate" })
}

# The shared warehouse that runs the masking-function SQL belongs to the env scope.
data "terraform_remote_state" "workspace" {
  count   = var.scope == "env" ? 1 : 0
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "50-workspace/${var.environment}/env.tfstate" })
}

variable "enable_data_classification" {
  description = "Scan domain and vault catalogs for sensitive columns (proposes class.* system tags)"
  type        = bool
  default     = true
}

locals {
  ws       = data.terraform_remote_state.foundation.outputs.workspaces[var.environment]
  sql_file = "${path.root}/../../sql/governance/masking_functions.sql"
  policies = module.naming.abac_policies

  classified = { for k, c in module.naming.catalogs : k => c if contains(["domain", "vault"], c.kind) }
}

# Masking functions are SQL objects; Terraform runs the SQL file through the
# Statement Execution API on the shared warehouse whenever the file changes.
resource "terraform_data" "masking_functions" {
  count            = var.scope == "env" ? 1 : 0
  triggers_replace = [filemd5(local.sql_file), data.terraform_remote_state.workspace[0].outputs.warehouse_ids["piq-shared"]]

  provisioner "local-exec" {
    command = join(" ", [
      "python3 ${path.root}/../../scripts/run_sql.py",
      "--host ${local.ws.url}",
      "--warehouse-id ${data.terraform_remote_state.workspace[0].outputs.warehouse_ids["piq-shared"]}",
      "--file ${local.sql_file}",
      "--set catalog=${var.environment}_platform",
    ])
  }
}

resource "databricks_policy_info" "mask" {
  for_each              = local.policies
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
resource "databricks_data_classification_catalog_config" "this" {
  for_each = var.enable_data_classification ? local.classified : {}
  parent   = "catalogs/${each.value.name}"
}

output "policies" {
  value = sort(keys(local.policies))
}
