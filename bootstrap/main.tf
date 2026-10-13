# =============================================================================
# bootstrap/ - run ONCE, locally, with your own Azure credentials (az login).
#
# Creates the three things CI needs before it can manage anything else:
#   1. Terraform remote-state storage (Entra-auth only, no shared keys)
#   2. The Terraform identity: Entra app + service principal "sp-<prefix>-terraform"
#   3. Trust between GitHub Actions and that identity (OIDC federated credentials)
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

  # GitHub OIDC subjects allowed to act as the Terraform SP.
  # environment:* subjects are used by apply jobs; pull_request by plan jobs.
  github_subjects = {
    pull-request = "repo:${local.repo}:pull_request"
    env-platform = "repo:${local.repo}:environment:platform"
  }

  # Microsoft Graph application permissions the Terraform SP needs.
  graph_roles = concat(
    ["Group.ReadWrite.All", "Application.ReadWrite.OwnedBy", "User.Read.All"],
    module.naming.test_users.enabled ? ["User.ReadWrite.All"] : [],
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
  for_each       = local.github_subjects
  application_id = azuread_application.terraform.id
  display_name   = "github-${each.key}"
  description    = "GitHub Actions: ${each.value}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = each.value
}

# -----------------------------------------------------------------------------
# Outputs: copy these into GitHub repository variables (RUNBOOK Phase 2).
# -----------------------------------------------------------------------------
output "github_variables" {
  description = "Set these as GitHub repository variables (not secrets; none are sensitive)"
  value = {
    AZURE_CLIENT_ID       = azuread_application.terraform.client_id
    AZURE_TENANT_ID       = local.p.azure.tenant_id
    AZURE_SUBSCRIPTION_ID = local.p.azure.subscription_id
  }
}

output "terraform_sp" {
  value = {
    display_name = azuread_application.terraform.display_name
    client_id    = azuread_application.terraform.client_id
    sp_object_id = azuread_service_principal.terraform.object_id
  }
}

output "next_steps" {
  value = <<-EOT
    1. Create GitHub environment "platform" with yourself as required reviewer.
    2. Add the github_variables above as repository variables.
    3. Run stack 10-foundation (RUNBOOK Phase 3).
  EOT
}
