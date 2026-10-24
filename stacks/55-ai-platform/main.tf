# =============================================================================
# 55-ai-platform - Vector Search endpoints, App Spaces, Lakebase projects.
# Model routing, guardrails and per-user AI budgets live in Unity AI Gateway:
# the AI budget is in stack 30; gateway endpoints are configured in bundles.
#
# One run owns one scope (see util/scope.py):
#   env            the environment's Vector Search endpoint
#   domain:<name>  that domain's App Space and Lakebase project
# State: 55-ai-platform/<env>/{env,domain-<name>}.tfstate. A run reads the usage
# policies of the SAME scope from 30-account.
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
    error_message = "55-ai-platform supports scopes env and domain:<name>."
  }
}

module "naming" {
  source      = "../../modules/naming"
  config_dir  = "${path.root}/../../config"
  environment = var.environment
  scope       = var.scope
}

locals {
  scope_slug = startswith(var.scope, "domain:") ? "domain-${trimprefix(var.scope, "domain:")}" : var.scope
}

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "10-foundation/${var.environment}/env.tfstate" })
}

data "terraform_remote_state" "account" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "30-account/${var.environment}/${local.scope_slug}.tfstate" })
}

locals {
  pg               = module.naming.platform_group_names
  usage_policy_ids = data.terraform_remote_state.account.outputs.usage_policy_ids
  domains_in_scope = startswith(var.scope, "domain:") ? { for d, c in module.naming.domains : d => c if d == trimprefix(var.scope, "domain:") } : {}
}

module "ai" {
  source    = "../../modules/ai_platform"
  providers = { databricks = databricks }

  env                = var.environment
  prod               = module.naming.env_tier[var.environment] == "prod"
  manage_env_objects = var.scope == "env"
  prefix             = module.naming.prefix
  domains            = local.domains_in_scope
  usage_policy_ids   = local.usage_policy_ids
  vector_search      = module.naming.workspace_objects.vector_search
  role_groups        = module.naming.role_groups[var.environment]
  admin_group        = local.pg["${var.environment}-workspace-admins"]
}

output "ai" {
  value = { vector_search = module.ai.vector_search_endpoint, app_spaces = module.ai.app_spaces }
}
