# =============================================================================
# 55-ai-platform - Vector Search endpoints, App Spaces, Lakebase projects.
# Model routing, guardrails and per-user AI budgets live in Unity AI Gateway:
# the AI budget is in stack 30; gateway endpoints are configured per domain in
# bundles (see docs/ARCHITECTURE.md, "AI and apps").
# =============================================================================

module "naming" {
  source     = "../../modules/naming"
  config_dir = "${path.root}/../../config"
}

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "10-foundation.tfstate" })
}

data "terraform_remote_state" "account" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "30-account.tfstate" })
}

locals {
  pg = module.naming.platform_groups
  role_groups = { for env in module.naming.env_keys : env => {
    for role in module.naming.roles : role => [
      for k, g in module.naming.functional_groups : g.name if g.env == env && g.role == role
    ]
  } }
  usage_policy_ids = data.terraform_remote_state.account.outputs.usage_policy_ids
}

module "ai_dev" {
  source           = "../../modules/ai_platform"
  providers        = { databricks = databricks.dev }
  env              = "dev"
  prefix           = module.naming.prefix
  domains          = module.naming.data_domains
  usage_policy_ids = local.usage_policy_ids
  vector_search    = module.naming.workspace_objects.vector_search
  role_groups      = local.role_groups["dev"]
  admin_group      = local.pg["dev-workspace-admins"].name
}

module "ai_prd" {
  source           = "../../modules/ai_platform"
  providers        = { databricks = databricks.prd }
  env              = "prd"
  prefix           = module.naming.prefix
  domains          = module.naming.data_domains
  usage_policy_ids = local.usage_policy_ids
  vector_search    = module.naming.workspace_objects.vector_search
  role_groups      = local.role_groups["prd"]
  admin_group      = local.pg["prd-workspace-admins"].name
}

output "ai" {
  value = {
    dev = { vector_search = module.ai_dev.vector_search_endpoint, app_spaces = module.ai_dev.app_spaces }
    prd = { vector_search = module.ai_prd.vector_search_endpoint, app_spaces = module.ai_prd.app_spaces }
  }
}
