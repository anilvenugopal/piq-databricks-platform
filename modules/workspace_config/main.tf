# =============================================================================
# modules/workspace_config - settings and WORKSPACE objects for one workspace.
#
# Unity Catalog grants decide what data a person may read. These objects decide
# what compute they may run it on. Both are needed; neither implies the other.
# =============================================================================

terraform {
  required_providers {
    databricks = { source = "databricks/databricks" }
  }
}

variable "env" { type = string }
variable "manage_workspace" {
  description = "true in the env scope: workspace settings, compute policies and system-table grants. A domain scope only receives its own warehouses."
  type        = bool
}
variable "prod" {
  description = "true when this environment is the prod tier (nonprod-only compute policies are skipped there)"
  type        = bool
}
variable "prefix" { type = string }
variable "ip_access_list" { type = list(string) }
variable "role_groups" {
  description = "role -> group names in this env, across all producer domains (for compute policies)"
  type        = map(list(string))
}
variable "warehouses" {
  description = "naming.warehouses[env]: name -> {size, max_clusters, auto_stop_mins, can_use, can_manage, tags}"
  type        = any
}
variable "cluster_policies" { type = any }
variable "is_monitoring_home" {
  description = "true for the workspace that hosts platform views and system-table grants"
  type        = bool
}
variable "monitoring_group" { type = string }
variable "system_schemas" { type = list(string) }

# -----------------------------------------------------------------------------
# Workspace settings
# -----------------------------------------------------------------------------
resource "databricks_workspace_conf" "this" {
  count = var.manage_workspace ? 1 : 0
  custom_config = {
    "enableTokensConfig"  = false # no personal access tokens: OAuth / Entra only
    "enableIpAccessLists" = length(var.ip_access_list) > 0
  }
}

resource "databricks_ip_access_list" "allow" {
  count        = var.manage_workspace && length(var.ip_access_list) > 0 ? 1 : 0
  label        = "${var.prefix}-${var.env}-allow"
  list_type    = "ALLOW"
  ip_addresses = var.ip_access_list
  depends_on   = [databricks_workspace_conf.this]
}

# New notebooks and queries default to the sandbox catalog, not to whatever
# catalog the workspace was created with.
resource "databricks_default_namespace_setting" "this" {
  count = var.manage_workspace ? 1 : 0
  namespace {
    value = "${var.env}_sandbox"
  }
}

# -----------------------------------------------------------------------------
# SQL warehouses (serverless). Dedicated per producer domain, vault and consumer
# domain, plus one shared warehouse. Names carry no environment; tags do, and
# piq_domain makes SQL spend attributable in system.billing.usage.
# -----------------------------------------------------------------------------
resource "databricks_sql_endpoint" "this" {
  for_each                  = var.warehouses
  name                      = each.key
  cluster_size              = each.value.size
  max_num_clusters          = each.value.max_clusters
  auto_stop_mins            = each.value.auto_stop_mins
  enable_serverless_compute = true
  warehouse_type            = "PRO"

  tags {
    dynamic "custom_tags" {
      for_each = each.value.tags
      content {
        key   = custom_tags.key
        value = custom_tags.value
      }
    }
  }
}

resource "databricks_permissions" "warehouse" {
  for_each        = var.warehouses
  sql_endpoint_id = databricks_sql_endpoint.this[each.key].id

  dynamic "access_control" {
    for_each = toset(each.value.can_use)
    content {
      group_name       = access_control.value
      permission_level = "CAN_USE"
    }
  }
  dynamic "access_control" {
    for_each = toset(each.value.can_manage)
    content {
      group_name       = access_control.value
      permission_level = "CAN_MANAGE"
    }
  }
}

# -----------------------------------------------------------------------------
# Compute policies for the (rare) classic clusters. Users cannot create
# unrestricted clusters: the default "users" group has no cluster-create
# entitlement, so a policy with CAN_USE is the only path.
# -----------------------------------------------------------------------------
locals {
  policies = var.manage_workspace ? { for k, p in var.cluster_policies : k => p if !(try(p.nonprod_only, false) && var.prod) } : {}
}

resource "databricks_cluster_policy" "this" {
  for_each    = local.policies
  name        = "${var.prefix}-${each.key}"
  description = each.value.description
  definition = jsonencode(merge(
    {
      "data_security_mode"           = { type = "allowlist", values = ["USER_ISOLATION", "SINGLE_USER"], defaultValue = "USER_ISOLATION" }
      "autoscale.max_workers"        = { type = "range", maxValue = each.value.max_workers, defaultValue = 1 }
      "custom_tags.piq_env"          = { type = "fixed", value = var.env }
      "custom_tags.piq_domain"       = { type = "unlimited", isOptional = false }
      "spark_version"                = { type = "unlimited", defaultValue = "auto:latest-lts" }
      "enable_local_disk_encryption" = { type = "fixed", value = true }
    },
    each.value.autotermination_minutes > 0 ? {
      "autotermination_minutes" = { type = "range", maxValue = each.value.autotermination_minutes, defaultValue = each.value.autotermination_minutes }
    } : {},
  ))
}

resource "databricks_permissions" "policy" {
  for_each          = local.policies
  cluster_policy_id = databricks_cluster_policy.this[each.key].id

  dynamic "access_control" {
    for_each = distinct(flatten([for r in each.value.CAN_USE : lookup(var.role_groups, r, [])]))
    content {
      group_name       = access_control.value
      permission_level = "CAN_USE"
    }
  }
}

# -----------------------------------------------------------------------------
# System tables: grant the monitoring group access to system schemas.
# The schemas themselves are MANAGED by Databricks automatically — no resource
# needed to enable them. databricks_system_schema has a provider bug (both
# create and import return an empty ID) so we rely on the MANAGED state.
# Done once, from the monitoring-home workspace (system tables are account-wide).
# -----------------------------------------------------------------------------
resource "databricks_grant" "system_catalog" {
  count      = var.manage_workspace && var.is_monitoring_home ? 1 : 0
  catalog    = "system"
  principal  = var.monitoring_group
  privileges = ["USE_CATALOG"]
}

resource "databricks_grant" "system_schema" {
  for_each   = var.manage_workspace && var.is_monitoring_home ? toset(concat(["billing", "information_schema"], var.system_schemas)) : toset([])
  schema     = "system.${each.value}"
  principal  = var.monitoring_group
  privileges = ["USE_SCHEMA", "SELECT"]
}

output "warehouse_ids" {
  value = { for k, w in databricks_sql_endpoint.this : k => w.id }
}
