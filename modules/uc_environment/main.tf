# =============================================================================
# modules/uc_environment - Unity Catalog objects for ONE environment.
#
# Called once per environment with that environment's WORKSPACE-level provider.
# Because catalogs, credentials and external locations are created ISOLATED
# through that workspace, Unity Catalog binds them to it: a prd catalog is not
# reachable from the dev workspace, whatever anyone's grants say.
#
# Chain for each catalog:
#   access connector (Azure MI) -> storage credential -> external location
#   -> catalog managed location -> schemas -> volumes -> grants -> tags
# =============================================================================

terraform {
  required_providers {
    databricks = { source = "databricks/databricks" }
  }
}

variable "env" { type = string }
variable "prefix" { type = string }
variable "workspace_id" { type = string }
variable "access_connector_id" { type = string }
variable "storage_account_name" { type = string }
variable "catalogs" { type = any }       # filtered to this env
variable "catalog_grants" { type = any } # catalog key -> list of {principal, privileges}
variable "schemas" { type = any }        # filtered to this env
variable "volumes" { type = any }        # filtered to this env

locals {
  credential_name = "${var.env}_lake_credential"
}

# Storage credential: Unity Catalog's handle on the Azure managed identity.
resource "databricks_storage_credential" "lake" {
  name    = local.credential_name
  comment = "Access connector for ${var.env} lake storage. Managed by terraform."
  azure_managed_identity {
    access_connector_id = var.access_connector_id
  }
  isolation_mode = "ISOLATION_MODE_ISOLATED"
}

# One external location per catalog container. Nobody but the owner (Terraform)
# gets privileges here; people reach data only through catalogs.
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
    piq_domain = each.value.domain
    managed_by = "terraform"
  }
}

# Explicit binding documents intent; ISOLATED catalogs are only usable from
# workspaces listed in their bindings.
resource "databricks_workspace_binding" "catalog" {
  for_each       = var.catalogs
  securable_name = databricks_catalog.this[each.key].name
  securable_type = "catalog"
  workspace_id   = var.workspace_id
  binding_type   = "BINDING_TYPE_READ_WRITE"
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
  properties = {
    piq_layer  = each.value.layer
    managed_by = "terraform"
  }
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
  schema_name  = databricks_schema.this["${each.value.catalog_key}.${each.value.schema}"].name
  name         = each.value.name
  volume_type  = "MANAGED"
  comment      = "Managed volume. Raw files here are NOT masked by ABAC; restrict access by grant."
}

# -----------------------------------------------------------------------------
# Governed tags on catalogs and schemas (values must exist in tag policies).
# -----------------------------------------------------------------------------
resource "databricks_entity_tag_assignment" "catalog_env" {
  for_each    = var.catalogs
  entity_type = "catalogs"
  entity_name = databricks_catalog.this[each.key].name
  tag_key     = "piq_env"
  tag_value   = each.value.env
}

resource "databricks_entity_tag_assignment" "catalog_domain" {
  for_each    = var.catalogs
  entity_type = "catalogs"
  entity_name = databricks_catalog.this[each.key].name
  tag_key     = "piq_domain"
  tag_value   = each.value.domain
}

resource "databricks_entity_tag_assignment" "schema_layer" {
  for_each    = var.schemas
  entity_type = "schemas"
  entity_name = databricks_schema.this[each.key].id
  tag_key     = "piq_layer"
  tag_value   = each.value.layer
}

output "catalog_names" {
  value = { for k, c in databricks_catalog.this : k => c.name }
}
