# =============================================================================
# 25-access - who is in which group, and which access requests are approved.
#
# This stack is the stand-in for an identity-governance tool (SailPoint, Saviynt,
# PingID, ...). It is the ONLY stack that adds people to groups or nests a consumer
# into a product or a group into a SAR. Everything else creates the groups and says
# what they may do.
#
# Input: config/entitlements/<env>/ (one folder per environment). To hand this job to
# an IAM tool: delete that folder and this stack. The group names (modules/naming)
# are the contract, so nothing else changes.
#
# One run per environment (scope access). State: 25-access/<env>/access.tfstate.
# Runs after 20-identity of the same environment (the groups must exist).
# =============================================================================

variable "environment" {
  description = "Environment to deploy (a key of environments in config/platform.yaml)"
  type        = string
}

variable "scope" {
  description = "Scope of this run; this stack only has the access scope"
  type        = string
  default     = "access"
  validation {
    condition     = var.scope == "access"
    error_message = "25-access only supports scope access."
  }
}

module "naming" {
  source      = "../../modules/naming"
  config_dir  = "${path.root}/../../config"
  environment = var.environment
  scope       = var.scope
}

data "azuread_domains" "initial" { only_initial = true }

locals {
  tenant_domain = data.azuread_domains.initial.domains[0].domain_name

  # Every group, user and test user this run touches already exists (stack 20); find them by name.
  group_keys = toset(concat(
    [for n in values(module.naming.access_nesting) : n.child],
    [for n in values(module.naming.access_nesting) : n.parent],
    [for m in values(module.naming.access_user_memberships) : m.group],
    [for m in values(module.naming.access_test_user_memberships) : m.group],
  ))
  upns       = toset([for m in values(module.naming.access_user_memberships) : m.upn])
  test_users = toset([for m in values(module.naming.access_test_user_memberships) : m.user])
}

data "azuread_group" "g" {
  for_each         = local.group_keys
  display_name     = module.naming.all_group_names[each.key]
  security_enabled = true
}

data "azuread_user" "member" {
  for_each            = local.upns
  user_principal_name = each.value
}

data "azuread_user" "test" {
  for_each            = local.test_users
  user_principal_name = "${each.key}@${local.tenant_domain}"
}

# Approvals: a consumer group joins a product group; a group joins a SAR.
resource "azuread_group_member" "nesting" {
  for_each         = module.naming.access_nesting
  group_object_id  = data.azuread_group.g[each.value.parent].object_id
  member_object_id = data.azuread_group.g[each.value.child].object_id
}

# People: personas, domain admins, sandbox users, experiment members.
resource "azuread_group_member" "user" {
  for_each         = module.naming.access_user_memberships
  group_object_id  = data.azuread_group.g[each.value.group].object_id
  member_object_id = data.azuread_user.member[each.value.upn].object_id
}

# Training-only test users (consumer groups are normally managed by their lead).
resource "azuread_group_member" "test_user" {
  for_each         = module.naming.access_test_user_memberships
  group_object_id  = data.azuread_group.g[each.value.group].object_id
  member_object_id = data.azuread_user.test[each.value.user].object_id
}

output "memberships" {
  description = "Counts of what this run manages"
  value = {
    nesting = length(azuread_group_member.nesting)
    users   = length(azuread_group_member.user)
    test    = length(azuread_group_member.test_user)
  }
}
