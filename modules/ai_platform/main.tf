# =============================================================================
# modules/ai_platform - shared AI and app infrastructure for one environment.
#
#   * Vector Search endpoint (+ ACL). Indexes themselves are UC objects in each
#     domain's `ai` schema, created by domain bundles - index access = data access.
#   * App Spaces per domain: a governance boundary for many Databricks Apps, with
#     the domain's serverless usage policy so app compute is attributed.
#   * Optional Lakebase (managed Postgres) project per domain for app/agent state.
#     Postgres roles are a SEPARATE permission layer, provisioned by the app's
#     bundle, not by Unity Catalog grants.
# =============================================================================

terraform {
  required_providers {
    databricks = { source = "databricks/databricks" }
  }
}

variable "env" { type = string }
variable "prefix" { type = string }
variable "domains" { type = any }
variable "usage_policy_ids" { type = map(string) }
variable "vector_search" { type = any }
variable "role_groups" { type = map(list(string)) }
variable "admin_group" { type = string }

resource "databricks_vector_search_endpoint" "this" {
  count            = var.vector_search.enabled ? 1 : 0
  name             = "${var.prefix}-${var.env}-vs"
  endpoint_type    = "STANDARD"
  budget_policy_id = lookup(var.usage_policy_ids, "${var.env}-platform", null)
}

resource "databricks_permissions" "vector_search" {
  count                     = var.vector_search.enabled ? 1 : 0
  vector_search_endpoint_id = databricks_vector_search_endpoint.this[0].endpoint_id

  dynamic "access_control" {
    for_each = distinct(flatten([for r in var.vector_search.CAN_USE : lookup(var.role_groups, r, [])]))
    content {
      group_name       = access_control.value
      permission_level = "CAN_USE"
    }
  }
  dynamic "access_control" {
    for_each = distinct(concat([var.admin_group], flatten([for r in var.vector_search.CAN_MANAGE : lookup(var.role_groups, r, [])])))
    content {
      group_name       = access_control.value
      permission_level = "CAN_MANAGE"
    }
  }
}

resource "databricks_app_space" "domain" {
  for_each        = { for k, d in var.domains : k => d if try(d.app_space, false) }
  name            = "${var.prefix}-${var.env}-${each.key}"
  description     = "Apps for the ${each.key} domain in ${var.env}. ${each.value.description}"
  usage_policy_id = lookup(var.usage_policy_ids, "${var.env}-${each.key}", null)
}

resource "databricks_postgres_project" "domain" {
  for_each   = { for k, d in var.domains : k => d if try(d.lakebase, false) }
  project_id = "${var.prefix}-${var.env}-${each.key}"
  spec = {
    pg_version       = 17
    display_name     = "${upper(var.env)} ${each.key} app and agent state"
    budget_policy_id = lookup(var.usage_policy_ids, "${var.env}-${each.key}", null)
    default_endpoint_settings = {
      autoscaling_limit_min_cu = 0.5
      autoscaling_limit_max_cu = var.env == "prd" ? 4 : 1
      suspend_timeout_duration = "300s" # scale to zero after 5 idle minutes
    }
    custom_tags = [
      { key = "piq_env", value = var.env },
      { key = "piq_domain", value = each.key },
    ]
  }
}

output "vector_search_endpoint" {
  value = var.vector_search.enabled ? databricks_vector_search_endpoint.this[0].name : null
}
output "app_spaces" {
  value = { for k, s in databricks_app_space.domain : k => s.name }
}
