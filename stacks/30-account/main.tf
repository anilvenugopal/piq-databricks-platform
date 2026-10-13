# =============================================================================
# 30-account - Databricks ACCOUNT-level configuration.
#
#   * Resolve Entra groups, service principals and users into the account (AIM)
#   * Assign groups and service principals to workspaces (USER / ADMIN)
#   * Serverless usage policies per env x owner (domain, vault, consumer,
#     platform, sandbox), and who may use them
#   * Budgets (alert-only) per environment, domain, vault, consumer, AI Gateway
#   * Serverless egress network policies per environment
# =============================================================================

module "naming" {
  source     = "../../modules/naming"
  config_dir = "${path.root}/../../config"
}

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "10-foundation.tfstate" })
}

data "terraform_remote_state" "identity" {
  backend = "azurerm"
  config  = merge(module.naming.state_backend, { key = "20-identity.tfstate" })
}

locals {
  account_id = module.naming.platform.databricks.account_id
  ws         = data.terraform_remote_state.foundation.outputs.workspaces
  groups     = data.terraform_remote_state.identity.outputs.groups
  sps        = data.terraform_remote_state.identity.outputs.service_principals
  users      = data.terraform_remote_state.identity.outputs.users
  envs       = module.naming.environments
  budgets    = module.naming.cost.budgets
}

# -----------------------------------------------------------------------------
# AIM resolution. Reading these data sources provisions the Entra identity in
# the Databricks account if needed and returns its internal id. Every group is
# resolved, including product, SAR and writer groups, because Unity Catalog
# grants refer to them by name.
# -----------------------------------------------------------------------------
data "databricks_account_iam_external_group_v2" "g" {
  for_each = local.groups
  name     = "accounts/${local.account_id}/external-groups/${each.value.object_id}"
}

data "databricks_account_iam_external_service_principal_v2" "sp" {
  for_each = local.sps
  name     = "accounts/${local.account_id}/external-service-principals/${each.value.object_id}"
}

data "databricks_account_iam_external_user_v2" "u" {
  for_each = { for upn in module.naming.granted_users : upn => local.users[upn] }
  name     = "accounts/${local.account_id}/external-users/${each.value}"
}

# -----------------------------------------------------------------------------
# Workspace assignments
# -----------------------------------------------------------------------------
resource "databricks_mws_permission_assignment" "group" {
  for_each     = module.naming.group_workspace_assignments
  workspace_id = local.ws[each.value.env].workspace_id
  principal_id = data.databricks_account_iam_external_group_v2.g[each.value.group].internal_id
  permissions  = [each.value.permission]
}

resource "databricks_mws_permission_assignment" "sp" {
  for_each     = module.naming.sp_workspace_assignments
  workspace_id = local.ws[each.value.env].workspace_id
  principal_id = data.databricks_account_iam_external_service_principal_v2.sp[each.value.sp].internal_id
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
  for_each     = local.envs
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

resource "databricks_budget" "ai_gateway" {
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
