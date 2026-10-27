# =============================================================================
# bootstrap/ - run ONCE, locally, with your own Azure credentials (az login).
#
# Creates what CI needs before it can manage anything else:
#   1. Terraform remote-state storage (Entra-auth only, no shared keys)
#   2. One resource group per environment (rg-<prefix>-<env>), so Azure rights can be
#      limited to it
#   3. The Terraform identities, with no secrets:
#        sp-<prefix>-terraform        shared scope and account-wide work
#        sp-<prefix>-terraform-<env>  one per environment, Azure rights limited to that
#                                     environment's resource group
#   4. Trust between GitHub Actions and each identity (OIDC federated credentials), by
#      GitHub environment name: <env> (apply), <env>-plan (plan), shared, shared-plan
#
# State for THIS stack stays local (bootstrap/terraform.tfstate, git-ignored).
# Keep a copy somewhere safe or migrate it into the state container afterwards
# (see docs/RUNBOOK.md, Phase 2).
# =============================================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
  }
}

module "naming" {
  source     = "../modules/naming"
  config_dir = "${path.root}/../config"
}

locals {
  p      = module.naming.platform
  prefix = module.naming.prefix
  repo   = "${local.p.github.org}/${local.p.github.platform_repo}"

  env_keys = module.naming.env_keys

  # GitHub OIDC subjects allowed to act as each identity. The shared identity trusts the
  # GitHub environments shared / shared-plan; an environment's identity trusts <env> / <env>-plan.
  # The -plan environments have no required reviewers; <env> (apply) does for the prod environment.
  shared_subjects = {
    shared      = "repo:${local.repo}:environment:shared"
    shared-plan = "repo:${local.repo}:environment:shared-plan"
  }
  env_subjects = merge([for e in local.env_keys : {
    "${e}"      = { env = e, subject = "repo:${local.repo}:environment:${e}" }
    "${e}-plan" = { env = e, subject = "repo:${local.repo}:environment:${e}-plan" }
  }]...)

  # Microsoft Graph application permissions the Terraform SP needs.
  graph_roles = concat(
    ["Group.ReadWrite.All", "Application.ReadWrite.OwnedBy", "User.Read.All"],
    length(module.naming.test_users) > 0 ? ["User.ReadWrite.All"] : [],
  )
}

provider "azurerm" {
  features {}
  subscription_id     = local.p.azure.subscription_id
  tenant_id           = local.p.azure.tenant_id
  storage_use_azuread = true
}

provider "azuread" {
  tenant_id = local.p.azure.tenant_id
}

data "azurerm_client_config" "me" {}
data "azuread_client_config" "me" {}
data "azurerm_subscription" "this" {}

# -----------------------------------------------------------------------------
# 1. Remote state storage
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "state" {
  name     = local.p.state.resource_group
  location = local.p.azure.location
  tags     = { piq_env = "shared", piq_domain = "platform", managed_by = "terraform-bootstrap" }
}

resource "azurerm_storage_account" "state" {
  name                            = local.p.state.storage_account
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false # Entra ID auth only
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true # every state write is recoverable
    delete_retention_policy { days = 30 }
    container_delete_retention_policy { days = 30 }
  }
  tags = azurerm_resource_group.state.tags
}

resource "azurerm_storage_container" "state" {
  name                  = local.p.state.container
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# You (the human running bootstrap) need data-plane access to the state too.
resource "azurerm_role_assignment" "state_me" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.me.object_id
}

# -----------------------------------------------------------------------------
# 2. Terraform identity
# -----------------------------------------------------------------------------
resource "azuread_application" "terraform" {
  display_name = "sp-${local.prefix}-terraform"
  owners       = [data.azuread_client_config.me.object_id]
  notes        = "Terraform automation identity for ${local.repo}. Created by bootstrap/."

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
    dynamic "resource_access" {
      for_each = local.graph_roles
      content {
        id   = data.azuread_service_principal.msgraph.app_role_ids[resource_access.value]
        type = "Role"
      }
    }
  }
}

resource "azuread_service_principal" "terraform" {
  client_id = azuread_application.terraform.client_id
  owners    = [data.azuread_client_config.me.object_id]
}

data "azuread_application_published_app_ids" "well_known" {}

# Read-only lookup of the Microsoft Graph service principal (never manage it).
data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

# Admin consent: assigning app roles directly is equivalent to granting consent.
resource "azuread_app_role_assignment" "graph" {
  for_each            = toset(local.graph_roles)
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.value]
  principal_object_id = azuread_service_principal.terraform.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Azure RBAC: create resources and role assignments (needed for access connectors).
resource "azurerm_role_assignment" "tf_contributor" {
  scope                = data.azurerm_subscription.this.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.terraform.object_id
}

resource "azurerm_role_assignment" "tf_rbac_admin" {
  scope                = data.azurerm_subscription.this.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.terraform.object_id
}

resource "azurerm_role_assignment" "tf_state" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.terraform.object_id
}

# -----------------------------------------------------------------------------
# 3. GitHub OIDC trust - no client secret ever exists for this identity.
# -----------------------------------------------------------------------------
resource "azuread_application_federated_identity_credential" "github" {
  for_each       = local.shared_subjects
  application_id = azuread_application.terraform.id
  display_name   = "github-${each.key}"
  description    = "GitHub Actions: ${each.value}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = each.value
}

# -----------------------------------------------------------------------------
# 4. Per-environment resource groups and Terraform identities.
#    The identity of an environment can create and manage resources only inside that
#    environment's resource group. Entra (Graph) and Databricks account rights cannot be
#    limited this way, so those stay tenant/account-wide: see docs/ARCHITECTURE.md.
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "env" {
  for_each = toset(local.env_keys)
  name     = "rg-${local.prefix}-${each.key}"
  location = local.p.azure.location
  tags     = { managed_by = "terraform", platform = local.prefix, piq_env = each.key }
}

resource "azuread_application" "env" {
  for_each     = toset(local.env_keys)
  display_name = "sp-${local.prefix}-terraform-${each.key}"
  owners       = [data.azuread_client_config.me.object_id]
  notes        = "Terraform automation identity for the ${each.key} environment of ${local.repo}. Created by bootstrap/."

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
    dynamic "resource_access" {
      for_each = local.graph_roles
      content {
        id   = data.azuread_service_principal.msgraph.app_role_ids[resource_access.value]
        type = "Role"
      }
    }
  }
}

resource "azuread_service_principal" "env" {
  for_each  = toset(local.env_keys)
  client_id = azuread_application.env[each.key].client_id
  owners    = [data.azuread_client_config.me.object_id]
}

locals {
  env_graph_grants = { for item in setproduct(local.env_keys, local.graph_roles) : "${item[0]}|${item[1]}" => { env = item[0], role = item[1] } }
}

resource "azuread_app_role_assignment" "env_graph" {
  for_each            = local.env_graph_grants
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.value.role]
  principal_object_id = azuread_service_principal.env[each.value.env].object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

resource "azurerm_role_assignment" "env_contributor" {
  for_each             = toset(local.env_keys)
  scope                = azurerm_resource_group.env[each.key].id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.env[each.key].object_id
}

resource "azurerm_role_assignment" "env_rbac_admin" {
  for_each             = toset(local.env_keys)
  scope                = azurerm_resource_group.env[each.key].id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.env[each.key].object_id
}

resource "azurerm_role_assignment" "env_state" {
  for_each             = toset(local.env_keys)
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.env[each.key].object_id
}

resource "azuread_application_federated_identity_credential" "env" {
  for_each       = local.env_subjects
  application_id = azuread_application.env[each.value.env].id
  display_name   = "github-${each.key}"
  description    = "GitHub Actions: ${each.value.subject}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = each.value.subject
}

# -----------------------------------------------------------------------------
# Outputs: copy these into the variables of the matching GitHub environments (RUNBOOK Phase 2).
# -----------------------------------------------------------------------------
output "github_variables" {
  description = "Set these as GitHub variables on the matching GitHub environment (not secrets; none are sensitive)"
  value = {
    shared = {
      AZURE_CLIENT_ID       = azuread_application.terraform.client_id
      AZURE_TENANT_ID       = local.p.azure.tenant_id
      AZURE_SUBSCRIPTION_ID = local.p.azure.subscription_id
    }
    by_environment = { for e in local.env_keys : e => {
      AZURE_CLIENT_ID       = azuread_application.env[e].client_id
      AZURE_TENANT_ID       = local.p.azure.tenant_id
      AZURE_SUBSCRIPTION_ID = local.p.azure.subscription_id
    } }
  }
}

output "terraform_sp" {
  value = {
    display_name = azuread_application.terraform.display_name
    client_id    = azuread_application.terraform.client_id
    sp_object_id = azuread_service_principal.terraform.object_id
  }
}

output "env_terraform_sps" {
  description = "Per-environment Terraform identities: add each as a Databricks ACCOUNT ADMIN (RUNBOOK Phase 4)"
  value = { for e in local.env_keys : e => {
    display_name = azuread_application.env[e].display_name
    client_id    = azuread_application.env[e].client_id
    sp_object_id = azuread_service_principal.env[e].object_id
  } }
}

output "next_steps" {
  value = <<-EOT
    1. Create GitHub environments: shared, shared-plan, and for each environment <env> and <env>-plan
       (required reviewers on the prod environment's apply environment).
    2. Set the github_variables above on the matching environment (shared -> shared and shared-plan;
       by_environment.<env> -> <env> and <env>-plan).
    3. Add every identity in env_terraform_sps and terraform_sp as a Databricks account admin (RUNBOOK Phase 4).
    4. Run stack 10-foundation for each environment (RUNBOOK Phase 3).
  EOT
}
