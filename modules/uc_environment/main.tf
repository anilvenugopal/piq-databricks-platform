# =============================================================================
# modules/uc_environment - Unity Catalog objects for ONE environment.
#
# Called once per environment with that environment's WORKSPACE-level provider.
# Catalogs, credentials and external locations are created ISOLATED through
# that workspace, so Unity Catalog binds them to it. Catalogs that list
# readonly_envs (prd_{domain}_anon) also get a READ_ONLY binding to those
# environments' workspaces.
#
# Chain per catalog:
#   access connector (Azure MI) -> storage credential -> external location
#   -> catalog managed location -> schemas -> volumes -> grants -> tags
# =============================================================================

terraform {
  required_providers {
    databricks = { source = "databricks/databricks" }
  }
}

variable "env" { type = string }
variable "workspace_id" { type = string }
variable "workspace_ids" {
  description = "env -> workspace id, for read-only bindings into other environments"
  type        = map(string)
}
variable "access_connector_id" { type = string }
variable "storage_account_name" { type = string }
variable "catalogs" { type = any }       # naming.catalogs filtered to this env
variable "catalog_grants" { type = any } # naming.catalog_grants (all envs)
variable "schemas" { type = any }        # naming.schemas filtered to this env
variable "volumes" { type = any }        # naming.volumes filtered to this env

resource "databricks_storage_credential" "lake" {
  name    = "${var.env}_lake_credential"
  comment = "Access connector for ${var.env} lake storage. Managed by terraform."
  azure_managed_identity {
    access_connector_id = var.access_connector_id
  }
  isolation_mode = "ISOLATION_MODE_ISOLATED"
}

# One external location per catalog container. Nobody but the owner (Terraform)
# holds privileges on it; people reach data only through catalogs.
resource "databricks_external_location" "catalog" {
  for_each        = var.catalogs
  name            = "${each.value.name}_root"
  url             = "abfss://${each.value.container}@${var.storage_account_name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.lake.id
  comment         = "Managed storage root for catalog ${each.value.name}"
  isolation_mode  = "ISOLATION_MODE_ISOLATED"
}

resource "databricks_catalog" "this" {
  for_each       = var.catalogs
  name           = each.value.name
  comment        = each.value.comment
  storage_root   = databricks_external_location.catalog[each.key].url
  isolation_mode = "ISOLATED"
  properties = {
    piq_env    = each.value.env
    piq_kind   = each.value.kind
    piq_domain = each.value.owner
    managed_by = "terraform"
  }
}

resource "databricks_workspace_binding" "catalog" {
  for_each       = var.catalogs
  securable_name = databricks_catalog.this[each.key].name
  securable_type = "catalog"
  workspace_id   = var.workspace_id
  binding_type   = "BINDING_TYPE_READ_WRITE"
}

# Read-only bindings into other environments (anonymized prd data read from dev).
locals {
  readonly_bindings = { for item in flatten([
    for ck, c in var.catalogs : [for e in c.readonly_envs : { key = "${ck}|${e}", catalog_key = ck, env = e }]
  ]) : item.key => item }
}

resource "databricks_workspace_binding" "readonly" {
  for_each       = local.readonly_bindings
  securable_name = databricks_catalog.this[each.value.catalog_key].name
  securable_type = "catalog"
  workspace_id   = var.workspace_ids[each.value.env]
  binding_type   = "BINDING_TYPE_READ_ONLY"
}

resource "databricks_grants" "catalog" {
  for_each = var.catalogs
  catalog  = databricks_catalog.this[each.key].name

  dynamic "grant" {
    for_each = var.catalog_grants[each.key]
    content {
      principal  = grant.value.principal
      privileges = grant.value.privileges
    }
  }
}

resource "databricks_schema" "this" {
  for_each     = var.schemas
  catalog_name = databricks_catalog.this[each.value.catalog_key].name
  name         = each.value.name
  comment      = each.value.comment
  properties   = merge(each.value.tags, { managed_by = "terraform" })
}

resource "databricks_grants" "schema" {
  for_each = { for k, s in var.schemas : k => s if length(s.grants) > 0 }
  schema   = databricks_schema.this[each.key].id

  dynamic "grant" {
    for_each = each.value.grants
    content {
      principal  = grant.value.principal
      privileges = grant.value.privileges
    }
  }
}

resource "databricks_volume" "this" {
  for_each     = var.volumes
  catalog_name = each.value.catalog
  schema_name  = databricks_schema.this[each.value.schema_key].name
  name         = each.value.name
  volume_type  = "MANAGED"
  comment      = "Managed volume. Files are NOT masked by ABAC; access is by grant only."
}

# -----------------------------------------------------------------------------
# Governed tags on catalogs and schemas (values must exist in tag policies).
# -----------------------------------------------------------------------------
locals {
  catalog_tags = merge(
    { for ck, c in var.catalogs : "${ck}|piq_env" => { catalog_key = ck, key = "piq_env", value = c.env } },
    { for ck, c in var.catalogs : "${ck}|piq_domain" => { catalog_key = ck, key = "piq_domain", value = c.owner } },
  )
  schema_tags = { for item in flatten([
    for sk, s in var.schemas : [for tk, tv in s.tags : { key = "${sk}|${tk}", schema_key = sk, tag = tk, value = tv }]
  ]) : item.key => item }
}

resource "databricks_entity_tag_assignment" "catalog" {
  for_each    = local.catalog_tags
  entity_type = "catalogs"
  entity_name = databricks_catalog.this[each.value.catalog_key].name
  tag_key     = each.value.key
  tag_value   = each.value.value
}

resource "databricks_entity_tag_assignment" "schema" {
  for_each    = local.schema_tags
  entity_type = "schemas"
  entity_name = databricks_schema.this[each.value.schema_key].id
  tag_key     = each.value.tag
  tag_value   = each.value.value
}

output "catalog_names" {
  value = { for k, c in databricks_catalog.this : k => c.name }
}
