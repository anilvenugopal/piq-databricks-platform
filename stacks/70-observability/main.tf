# =============================================================================
# 70-observability - platform views over system tables, in prd_platform.
# System tables are account-wide, so one set of views covers both environments.
# Grants on the monitoring/observability/audit/governance schemas come from
# stack 40 (platform-monitoring group: USE_SCHEMA + SELECT).
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

locals {
  home      = "prd"
  sql_root  = "${path.root}/../../sql/observability"
  sql_files = fileset(local.sql_root, "*/*.sql")
}

resource "terraform_data" "view" {
  for_each         = local.sql_files
  triggers_replace = [filemd5("${local.sql_root}/${each.value}")]

  provisioner "local-exec" {
    command = join(" ", [
      "python3 ${path.root}/../../scripts/run_sql.py",
      "--host ${data.terraform_remote_state.foundation.outputs.workspaces[local.home].url}",
      "--warehouse-id ${data.terraform_remote_state.workspace.outputs.warehouse_ids[local.home]["piq-shared"]}",
      "--file ${local.sql_root}/${each.value}",
      "--set catalog=${local.home}_platform",
    ])
  }
}

output "views" {
  value = sort([for f in local.sql_files : "${local.home}_platform.${replace(trimsuffix(f, ".sql"), "/", ".")}"])
}
