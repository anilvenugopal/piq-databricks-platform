# =============================================================================
# 30-account - Databricks ACCOUNT-level configuration.
#
#   * Resolve Entra groups, service principals and users into the account (AIM)
#   * Assign groups and service principals to workspaces (USER / ADMIN)
#   * Serverless usage policies per env x owner (domain, vault, consumer,
#     platform, sandbox), and who may use them
#   * Budgets (alert-only) per environment, domain, vault, consumer, AI Gateway
#   * Serverless egress network policies per environment
#
# One run owns one scope (see util/scope.py):
#   shared         the AI Gateway budget (one for the whole account)
#   env            the environment's workspace assignments, usage policies, budgets, egress policy
#   domain:<name>  that domain's workspace assignments, usage policy and budget
# State: 30-account/shared.tfstate or 30-account/<env>/{env,domain-<name>}.tfstate.
#
# Groups, service principals and users are found in Entra BY NAME (stack 20 ran
# first), so no run needs another run's state.
# =============================================================================

variable "environment" {
  description = "Environment of this run; unset for scope shared"
  type        = string
  default     = null
}

variable "scope" {
  description = "shared | env | domain:<name>"
  type        = string
  validation {
    condition     = contains(["shared", "env"], var.scope) || startswith(var.scope, "domain:")
    error_message = "30-account supports scopes shared, env and domain:<name>."
  }
}

module "naming" {
  source      = "../../modules/naming"
  config_dir  = "${path.root}/../../config"
  environment = var.environment
  scope       = var.scope
}

data "terraform_remote_state" "foundation" {
  count   = var.scope == "shared" ? 0 : 1
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "10-foundation/${var.environment}/env.tfstate" })
}

locals {
  account_id = module.naming.platform.databricks.account_id
  # env -> workspace ids. Only the run's own environment is needed.
  ws   = var.scope == "shared" ? {} : data.terraform_remote_state.foundation[0].outputs.workspaces
  envs = { for e, c in module.naming.environments : e => c if var.scope == "env" && e == var.environment }
  # An environment budget is optional: no entry in cost.yaml environment_monthly_usd, no budget.
  env_budgets = { for e, c in local.envs : e => c if try(local.budgets.environment_monthly_usd[e], 0) > 0 }
  budgets     = module.naming.cost.budgets

  # Every group this run's objects name: the groups it owns, the groups assigned to a
  # workspace, and the principals of its grants, policies and warehouses. Unity Catalog
  # refers to them by name, so each must be resolved into the account first.
  all_group_names = values(module.naming.all_group_names)
  referenced_principals = distinct(flatten([
    [for ck, gs in module.naming.catalog_grants : [for g in gs : g.principal]],
    [for sk, s in module.naming.schemas : [for g in s.grants : g.principal]],
    [for pk, p in module.naming.abac_policies : p.except],
    [for e, ws in module.naming.warehouses : [for n, w in ws : concat(w.can_use, w.can_manage)]],
    [for k, u in module.naming.usage_scopes : u.principals],
  ]))
  group_names = toset(concat(
    [for k, g in module.naming.groups : g.name],
    [for a in values(module.naming.group_workspace_assignments) : module.naming.all_group_names[a.group]],
    [for p in local.referenced_principals : p if contains(local.all_group_names, p)],
    length(module.naming.usage_scopes) > 0 ? [module.naming.platform_group_names["mesh-admins"]] : [],
  ))
  sp_names = toset(concat(
    [for k, s in module.naming.service_principals : s.display_name],
    [for a in values(module.naming.sp_workspace_assignments) : module.naming.all_service_principal_names[a.sp]],
  ))
}

# -----------------------------------------------------------------------------
# AIM resolution. Reading these data sources provisions the Entra identity in
# the Databricks account if needed and returns its internal id.
# -----------------------------------------------------------------------------
data "azuread_group" "g" {
  for_each         = local.group_names
  display_name     = each.value
  security_enabled = true
}

data "azuread_service_principal" "sp" {
  for_each     = local.sp_names
  display_name = each.value
}

data "azuread_user" "u" {
  for_each            = toset(module.naming.granted_users)
  user_principal_name = each.value
}

data "databricks_account_iam_external_group_v2" "g" {
  for_each = data.azuread_group.g
  name     = "accounts/${local.account_id}/external-groups/${each.value.object_id}"
}

data "databricks_account_iam_external_service_principal_v2" "sp" {
  for_each = data.azuread_service_principal.sp
  name     = "accounts/${local.account_id}/external-service-principals/${each.value.object_id}"
}

data "databricks_account_iam_external_user_v2" "u" {
  for_each = data.azuread_user.u
  name     = "accounts/${local.account_id}/external-users/${each.value.object_id}"
}

# -----------------------------------------------------------------------------
# Workspace assignments
# -----------------------------------------------------------------------------
resource "databricks_mws_permission_assignment" "group" {
  for_each     = module.naming.group_workspace_assignments
  workspace_id = local.ws[each.value.env].workspace_id
  principal_id = data.databricks_account_iam_external_group_v2.g[module.naming.all_group_names[each.value.group]].internal_id
  permissions  = [each.value.permission]
}

resource "databricks_mws_permission_assignment" "sp" {
  for_each     = module.naming.sp_workspace_assignments
  workspace_id = local.ws[each.value.env].workspace_id
  principal_id = data.databricks_account_iam_external_service_principal_v2.sp[module.naming.all_service_principal_names[each.value.sp]].internal_id
  permissions  = [each.value.permission]
}

# -----------------------------------------------------------------------------
# Serverless usage policies: tags on every serverless DBU their users consume.
# SQL warehouses are attributed by their own piq_domain tag (stack 50).
# -----------------------------------------------------------------------------
resource "databricks_budget_policy" "usage" {
  for_each              = module.naming.usage_scopes
  policy_name           = each.value.name
  binding_workspace_ids = [tonumber(local.ws[each.value.env].workspace_id)]
  custom_tags = [
    { key = "piq_env", value = each.value.env },
    { key = "piq_domain", value = each.value.owner },
  ]
}

resource "databricks_access_control_rule_set" "usage" {
  for_each = module.naming.usage_scopes
  name     = "accounts/${local.account_id}/budgetPolicies/${databricks_budget_policy.usage[each.key].policy_id}/ruleSets/default"

  grant_rules {
    principals = ["groups/${module.naming.platform_group_names["mesh-admins"]}"]
    role       = "roles/budgetPolicy.manager"
  }
  grant_rules {
    principals = [for g in each.value.principals : "groups/${g}"]
    role       = "roles/budgetPolicy.user"
  }
}

# -----------------------------------------------------------------------------
# Budgets: notify, never suspend.
# -----------------------------------------------------------------------------
locals {
  scope_budget_usd = { for k, s in module.naming.usage_scopes : k => (
    s.kind == "domain" ? try(local.budgets.domain_monthly_usd[s.env], 0) :
    s.kind == "vault" ? try(local.budgets.vault_monthly_usd[s.env], 0) :
    s.kind == "consumer" ? try(local.budgets.consumer_monthly_usd[s.env], 0) : 0
  ) }
  scoped_budgets = { for k, s in module.naming.usage_scopes : k => s if local.scope_budget_usd[k] > 0 }
}

resource "databricks_budget" "environment" {
  for_each     = local.env_budgets
  display_name = "${module.naming.prefix}-${each.key}-workspace"

  dynamic "alert_configurations" {
    for_each = local.budgets.alert_at_percent
    content {
      time_period        = "MONTH"
      trigger_type       = "CUMULATIVE_SPENDING_EXCEEDED"
      quantity_type      = "LIST_PRICE_DOLLARS_USD"
      quantity_threshold = tostring(floor(local.budgets.environment_monthly_usd[each.key] * alert_configurations.value / 100))
      action_configurations {
        action_type = "EMAIL_NOTIFICATION"
        target      = module.naming.platform.notifications.ops_email
      }
    }
  }

  filter {
    workspace_id {
      operator = "IN"
      values   = [tonumber(local.ws[each.key].workspace_id)]
    }
  }
}

resource "databricks_budget" "scope" {
  for_each     = local.scoped_budgets
  display_name = each.value.name

  dynamic "alert_configurations" {
    for_each = local.budgets.alert_at_percent
    content {
      time_period        = "MONTH"
      trigger_type       = "CUMULATIVE_SPENDING_EXCEEDED"
      quantity_type      = "LIST_PRICE_DOLLARS_USD"
      quantity_threshold = tostring(floor(local.scope_budget_usd[each.key] * alert_configurations.value / 100))
      action_configurations {
        action_type = "EMAIL_NOTIFICATION"
        target      = module.naming.platform.notifications.ops_email
      }
    }
  }

  filter {
    tags {
      key = "piq_env"
      value {
        operator = "IN"
        values   = [each.value.env]
      }
    }
    tags {
      key = "piq_domain"
      value {
        operator = "IN"
        values   = [each.value.owner]
      }
    }
  }
}

# One AI Gateway budget for the whole account, so it belongs to the shared scope.
resource "databricks_budget" "ai_gateway" {
  count         = var.scope == "shared" ? 1 : 0
  display_name  = "${module.naming.prefix}-ai-gateway"
  resource_type = "BUDGET_RESOURCE_TYPE_UNITY_AI_GATEWAY"

  alert_configurations {
    time_period        = "MONTH"
    trigger_type       = "CUMULATIVE_SPENDING_EXCEEDED"
    quantity_type      = "LIST_PRICE_DOLLARS_USD"
    quantity_threshold = tostring(local.budgets.ai_gateway_monthly_usd)
    scope_type         = "ALERT_CONFIGURATION_SCOPE_TYPE_SHARED"
    action_configurations {
      action_type = "EMAIL_NOTIFICATION"
      target      = module.naming.platform.notifications.ops_email
    }
  }
}

# -----------------------------------------------------------------------------
# Serverless egress control. Start in DRY_RUN, read the denials, then ENFORCE.
# -----------------------------------------------------------------------------
resource "databricks_account_network_policy" "env" {
  for_each          = local.envs
  network_policy_id = "${module.naming.prefix}-${each.key}-egress"
  egress = {
    network_access = {
      restriction_mode = each.value.serverless_egress.restriction_mode
      allowed_internet_destinations = [
        for d in each.value.serverless_egress.allowed_domains : {
          destination               = d
          internet_destination_type = "DNS_NAME"
        }
      ]
      policy_enforcement = {
        enforcement_mode = each.value.serverless_egress.enforcement_mode
      }
    }
  }
}

resource "databricks_workspace_network_option" "env" {
  for_each          = local.envs
  workspace_id      = local.ws[each.key].workspace_id
  network_policy_id = databricks_account_network_policy.env[each.key].network_policy_id
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "usage_policy_ids" {
  description = "usage scope key (env:owner) -> policy id"
  value       = { for k, p in databricks_budget_policy.usage : k => p.policy_id }
}
