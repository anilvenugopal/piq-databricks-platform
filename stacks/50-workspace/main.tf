# =============================================================================
# 50-workspace - workspace settings, SQL warehouses, compute policies and
# system-table access. One module call per environment.
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
  pg             = module.naming.platform_group_names
  system_schemas = ["access", "compute", "lakeflow", "query", "serving"]
}

module "ws_dev" {
  source    = "../../modules/workspace_config"
  providers = { databricks = databricks.dev }

  env                = "dev"
  prefix             = module.naming.prefix
  ip_access_list     = module.naming.environments["dev"].ip_access_list
  role_groups        = module.naming.role_groups["dev"]
  warehouses         = module.naming.warehouses["dev"]
  cluster_policies   = module.naming.workspace_objects.cluster_policies
  is_monitoring_home = false
  monitoring_group   = local.pg["platform-monitoring"]
  system_schemas     = local.system_schemas
}

module "ws_prd" {
  source    = "../../modules/workspace_config"
  providers = { databricks = databricks.prd }

  env                = "prd"
  prefix             = module.naming.prefix
  ip_access_list     = module.naming.environments["prd"].ip_access_list
  role_groups        = module.naming.role_groups["prd"]
  warehouses         = module.naming.warehouses["prd"]
  cluster_policies   = module.naming.workspace_objects.cluster_policies
  is_monitoring_home = true
  monitoring_group   = local.pg["platform-monitoring"]
  system_schemas     = local.system_schemas
}

output "warehouse_ids" {
  description = "env -> warehouse name -> id"
  value       = { dev = module.ws_dev.warehouse_ids, prd = module.ws_prd.warehouse_ids }
}
