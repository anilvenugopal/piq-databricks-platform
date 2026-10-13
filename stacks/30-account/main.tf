# =============================================================================
# 30-account - Databricks ACCOUNT-level configuration.
#
#   * Resolve Entra groups / service principals / users into the account (AIM)
#   * Assign groups and service principals to workspaces (USER / ADMIN)
#   * Serverless usage policies (cost attribution tags) + who may use them
#   * Budgets (alert-only) per environment, per domain, and for AI Gateway
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
  cost       = module.naming.cost
}

# -----------------------------------------------------------------------------
# AIM resolution. Reading these data sources provisions the Entra identity in
# the Databricks account if it is not there yet, and returns its internal id.
# -----------------------------------------------------------------------------
data "databricks_account_iam_external_group_v2" "g" {
  for_each = local.groups
  name     = "accounts/${local.account_id}/external-groups/${each.value.object_id}"
}

data "databricks_account_iam_external_service_principal_v2" "sp" {
  for_each = local.sps
  name     = "accounts/${local.account_id}/external-service-principals/${each.value.object_id}"
}

# Users referenced directly by UC grants (sandbox/experiment schemas) must exist.
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
# Serverless usage policies (formerly "budget policies"): tags that land on every
# serverless DBU a member consumes. This is how shared serverless compute is
# attributed to env x domain in system.billing.usage.custom_tags.
# -----------------------------------------------------------------------------
locals {
  usage_scopes = local.cost.usage_policies.enabled ? merge(
    { for pair in setproduct(module.naming.env_keys, module.naming.domain_keys) :
      "${pair[0]}-${pair[1]}" => { env = pair[0], domain = pair[1] }
    },
    { for env in module.naming.env_keys : "${env}-sandbox" => { env = env, domain = "sandbox" } },
    { for env in module.naming.env_keys : "${env}-platform" => { env = env, domain = "platform" } },
  ) : {}

  # Who may run under each policy: the domain's functional groups and SPs in that env.
  usage_principals = { for k, s in local.usage_scopes : k => (
    s.domain == "sandbox" ? ["groups/${local.groups[s.env == "dev" ? "pl:sandbox-users" : "pl:prd-experimenters"].name}"] :
    s.domain == "platform" ? ["groups/${local.groups["pl:platform-monitoring"].name}", "groups/${local.groups["pl:governance-admins"].name}"] :
    [for role in module.naming.roles : "groups/${local.groups["fn:${s.env}-${s.domain}-${role}"].name}"]
  ) }
}

resource "databricks_budget_policy" "usage" {
  for_each              = local.usage_scopes
  policy_name           = "${module.naming.prefix}-${each.key}"
  binding_workspace_ids = [tonumber(local.ws[each.value.env].workspace_id)]
  custom_tags = [
    { key = "piq_env", value = each.value.env },
    { key = "piq_domain", value = each.value.domain },
  ]
}

resource "databricks_access_control_rule_set" "usage" {
  for_each = local.usage_scopes
  name     = "accounts/${local.account_id}/budgetPolicies/${databricks_budget_policy.usage[each.key].policy_id}/ruleSets/default"

  grant_rules {
    principals = ["groups/${local.groups["pl:account-admins"].name}"]
    role       = "roles/budgetPolicy.manager"
  }
  grant_rules {
    principals = local.usage_principals[each.key]
    role       = "roles/budgetPolicy.user"
  }
}

# -----------------------------------------------------------------------------
# Budgets: notify, never suspend. (Hard limits come from compute settings.)
# -----------------------------------------------------------------------------
locals {
  thresholds = local.cost.budgets.alert_at_percent
}

resource "databricks_budget" "environment" {
  for_each     = local.envs
  display_name = "${module.naming.prefix}-${each.key}-workspace"

  dynamic "alert_configurations" {
    for_each = local.thresholds
    content {
      time_period        = "MONTH"
      trigger_type       = "CUMULATIVE_SPENDING_EXCEEDED"
      quantity_type      = "LIST_PRICE_DOLLARS_USD"
      quantity_threshold = tostring(floor(local.cost.budgets.environment_monthly_usd[each.key] * alert_configurations.value / 100))
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

resource "databricks_budget" "domain" {
  for_each     = { for k, s in local.usage_scopes : k => s if contains(module.naming.domain_keys, s.domain) }
  display_name = "${module.naming.prefix}-${each.key}"

  dynamic "alert_configurations" {
    for_each = local.thresholds
    content {
      time_period        = "MONTH"
      trigger_type       = "CUMULATIVE_SPENDING_EXCEEDED"
      quantity_type      = "LIST_PRICE_DOLLARS_USD"
      quantity_threshold = tostring(floor(local.cost.budgets.domain_monthly_usd[each.value.env] * alert_configurations.value / 100))
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
        values   = [each.value.domain]
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
    quantity_threshold = tostring(local.cost.budgets.ai_gateway_monthly_usd)
    scope_type         = "ALERT_CONFIGURATION_SCOPE_TYPE_SHARED"
    action_configurations {
      action_type = "EMAIL_NOTIFICATION"
      target      = module.naming.platform.notifications.ops_email
    }
  }
}

# -----------------------------------------------------------------------------
# Serverless egress control: where serverless compute (jobs, SQL, apps, agents)
# may send traffic. Start in DRY_RUN, read the denial logs, then ENFORCE.
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
  value = { for k, p in databricks_budget_policy.usage : k => p.policy_id }
}

output "group_internal_ids" {
  value = { for k, g in data.databricks_account_iam_external_group_v2.g : k => g.internal_id }
}
