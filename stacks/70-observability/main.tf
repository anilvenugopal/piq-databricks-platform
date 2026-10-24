# =============================================================================
# 70-observability - platform views over system tables, in <prod env>_platform.
# System tables are account-wide, so one set of views covers every environment;
# they live in the prod environment, so this stack only runs there (scope env).
# Grants on the monitoring/observability/audit/governance schemas come from
# stack 40 (platform-monitoring group: USE_SCHEMA + SELECT).
# State: 70-observability/<prod env>/env.tfstate.
# =============================================================================

variable "environment" {
  description = "Environment to deploy; must be the prod environment"
  type        = string
}

variable "scope" {
  description = "Scope of this run; this stack only has the env scope"
  type        = string
  default     = "env"
  validation {
    condition     = var.scope == "env"
    error_message = "70-observability only supports scope env."
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

data "terraform_remote_state" "workspace" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "50-workspace/${var.environment}/env.tfstate" })
}

locals {
  home      = var.environment
  sql_root  = "${path.root}/../../sql/observability"
  sql_files = fileset(local.sql_root, "*/*.sql")
}

resource "terraform_data" "view" {
  lifecycle {
    precondition {
      condition     = var.environment == module.naming.prod_env
      error_message = "70-observability runs only in the prod environment (${module.naming.prod_env}); system tables are account-wide."
    }
  }

  for_each         = local.sql_files
  triggers_replace = [filemd5("${local.sql_root}/${each.value}")]

  provisioner "local-exec" {
    command = join(" ", [
      "python3 ${path.root}/../../scripts/run_sql.py",
      "--host ${data.terraform_remote_state.foundation.outputs.workspaces[local.home].url}",
      "--warehouse-id ${data.terraform_remote_state.workspace.outputs.warehouse_ids["piq-shared"]}",
      "--file ${local.sql_root}/${each.value}",
      "--set catalog=${local.home}_platform",
    ])
  }
}

output "views" {
  value = sort([for f in local.sql_files : "${local.home}_platform.${replace(trimsuffix(f, ".sql"), "/", ".")}"])
}
