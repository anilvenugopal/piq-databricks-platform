# =============================================================================
# 50-workspace - workspace settings, SQL warehouses, compute policies,
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
  wsobj = module.naming.workspace_objects
  pg    = module.naming.platform_groups

  # env -> role -> [group names across all data domains]; plus the sandbox group
  role_groups = { for env in module.naming.env_keys : env => merge(
    { for role in module.naming.roles : role => [
      for k, g in module.naming.functional_groups : g.name if g.env == env && g.role == role
    ] },
    { sandbox = env == "dev" ? [local.pg["sandbox-users"].name] : [local.pg["prd-experimenters"].name] },
  ) }

  system_schemas = ["access", "compute", "lakeflow", "query", "serving"]
}

module "ws_dev" {
  source    = "../../modules/workspace_config"
  providers = { databricks = databricks.dev }

  env                = "dev"
  prefix             = module.naming.prefix
  ip_access_list     = module.naming.environments["dev"].ip_access_list
  role_groups        = local.role_groups["dev"]
  admin_group        = local.pg["dev-workspace-admins"].name
  warehouses         = local.wsobj.sql_warehouses
  cluster_policies   = local.wsobj.cluster_policies
  is_monitoring_home = false
  monitoring_group   = local.pg["platform-monitoring"].name
  system_schemas     = local.system_schemas
}

module "ws_prd" {
  source    = "../../modules/workspace_config"
  providers = { databricks = databricks.prd }

  env                = "prd"
  prefix             = module.naming.prefix
  ip_access_list     = module.naming.environments["prd"].ip_access_list
  role_groups        = local.role_groups["prd"]
  admin_group        = local.pg["prd-workspace-admins"].name
  warehouses         = local.wsobj.sql_warehouses
  cluster_policies   = local.wsobj.cluster_policies
  is_monitoring_home = true
  monitoring_group   = local.pg["platform-monitoring"].name
  system_schemas     = local.system_schemas
}

output "warehouse_ids" {
  value = { dev = module.ws_dev.warehouse_ids, prd = module.ws_prd.warehouse_ids }
}
