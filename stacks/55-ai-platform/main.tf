# =============================================================================
# 55-ai-platform - Vector Search endpoints, App Spaces, Lakebase projects.
# Model routing, guardrails and per-user AI budgets live in Unity AI Gateway:
# the AI budget is in stack 30; gateway endpoints are configured in bundles.
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
  pg               = module.naming.platform_group_names
  usage_policy_ids = data.terraform_remote_state.account.outputs.usage_policy_ids
}

module "ai_dev" {
  source           = "../../modules/ai_platform"
  providers        = { databricks = databricks.dev }
  env              = "dev"
  prefix           = module.naming.prefix
  domains          = module.naming.domains
  usage_policy_ids = local.usage_policy_ids
  vector_search    = module.naming.workspace_objects.vector_search
  role_groups      = module.naming.role_groups["dev"]
  admin_group      = local.pg["dev-workspace-admins"]
}

module "ai_prd" {
  source           = "../../modules/ai_platform"
  providers        = { databricks = databricks.prd }
  env              = "prd"
  prefix           = module.naming.prefix
  domains          = module.naming.domains
  usage_policy_ids = local.usage_policy_ids
  vector_search    = module.naming.workspace_objects.vector_search
  role_groups      = module.naming.role_groups["prd"]
  admin_group      = local.pg["prd-workspace-admins"]
}

output "ai" {
  value = {
    dev = { vector_search = module.ai_dev.vector_search_endpoint, app_spaces = module.ai_dev.app_spaces }
    prd = { vector_search = module.ai_prd.vector_search_endpoint, app_spaces = module.ai_prd.app_spaces }
  }
}
