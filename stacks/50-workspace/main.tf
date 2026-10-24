# =============================================================================
# 50-workspace - workspace settings, SQL warehouses, compute policies and
# system-table access for ONE environment's workspace.
#
# One run owns one scope (see util/scope.py):
#   env            workspace settings, IP list, default namespace, compute policies,
#                  system-table grants, and the environment's own warehouses
#                  (vault, consumer, shared)
#   domain:<name>  that domain's transform warehouse and its permissions
# State: 50-workspace/<env>/{env,domain-<name>}.tfstate.
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
    error_message = "50-workspace supports scopes env and domain:<name>."
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

locals {
  pg             = module.naming.platform_group_names
  system_schemas = ["access", "compute", "lakeflow", "query", "serving"]
}

module "ws" {
  source    = "../../modules/workspace_config"
  providers = { databricks = databricks }

  env                = var.environment
  manage_workspace   = var.scope == "env"
  prod               = module.naming.env_tier[var.environment] == "prod"
  prefix             = module.naming.prefix
  ip_access_list     = module.naming.environments[var.environment].ip_access_list
  role_groups        = module.naming.role_groups[var.environment]
  warehouses         = module.naming.warehouses[var.environment]
  cluster_policies   = module.naming.workspace_objects.cluster_policies
  is_monitoring_home = var.environment == module.naming.prod_env
  monitoring_group   = local.pg["platform-monitoring"]
  system_schemas     = local.system_schemas
}

output "warehouse_ids" {
  description = "warehouse name -> id, for the warehouses this run owns"
  value       = module.ws.warehouse_ids
}
