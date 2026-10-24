# =============================================================================
# 20-identity - Microsoft Entra ID: groups, nesting, service principals.
#
# Entra is the single source of truth for identity. Databricks automatic
# identity management (AIM) makes these groups and principals visible in the
# account without SCIM; Databricks shows them as External and read-only.
#
# Group kinds (see modules/naming): domain local roles, writer, vault, product,
# consumer, SAR, platform, persona. Consumer groups are owned by the consumer
# lead, who manages their membership; Terraform never adds or removes members
# there (except training test users).
# =============================================================================

# One run owns one scope (see util/scope.py):
#   shared         cross-environment platform groups, extra SPs spanning environments, test users
#   env            one environment's groups, vault/SAR/consumer groups, global personas, loaders
#   domain:<name>  one domain's role/writer/product groups, domain personas, deploy SP
# People and approvals (who is in which group) are NOT here: they are entitlements, stack 25.
# State: 20-identity/shared.tfstate or 20-identity/<env>/{env,domain-<name>}.tfstate.

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
    error_message = "20-identity supports scopes shared, env and domain:<name>."
  }
}

module "naming" {
  source      = "../../modules/naming"
  config_dir  = "${path.root}/../../config"
  environment = var.environment
  scope       = var.scope
}

data "azuread_client_config" "current" {}
data "azuread_domains" "initial" { only_initial = true }

locals {
  tf_owner      = data.azuread_client_config.current.object_id
  tenant_domain = data.azuread_domains.initial.domains[0].domain_name
  leads         = distinct([for g in values(module.naming.groups) : g.lead if g.lead != ""])
  resolve_leads = try(module.naming.platform.identity.resolve_consumer_leads, false) && length(local.leads) > 0
  lead_ids = local.resolve_leads ? zipmap(
    data.azuread_users.leads[0].user_principal_names, data.azuread_users.leads[0].object_ids
  ) : {}
}

# Consumer leads become Entra owners of their consumer groups. Enable with
# identity.resolve_consumer_leads in platform.yaml once the leads exist in
# Entra; missing leads are skipped (the lookup fails only if none exist).
data "azuread_users" "leads" {
  count                = local.resolve_leads ? 1 : 0
  user_principal_names = local.leads
  ignore_missing       = true
}

# -----------------------------------------------------------------------------
# Groups
# -----------------------------------------------------------------------------
resource "azuread_group" "this" {
  for_each                = module.naming.groups
  display_name            = each.value.name
  description             = "${each.value.description} | managed by terraform"
  security_enabled        = true
  prevent_duplicate_names = true
  owners = distinct(concat(
    [local.tf_owner],
    each.value.lead != "" && contains(keys(local.lead_ids), each.value.lead) ? [local.lead_ids[each.value.lead]] : [],
  ))
}

# Group-in-group membership: personas into roles. Child is a member of parent.
# An edge belongs to the scope of its PARENT, except an edge into a shared group, which
# belongs to the CHILD's scope. A group owned by another scope (on either side) is found
# by its display name: that scope was applied earlier.
locals {
  nesting_groups = toset(flatten([for n in values(module.naming.nesting) : [n.child, n.parent]]))
  nesting_ext    = toset([for k in local.nesting_groups : k if !contains(keys(module.naming.groups), k)])
  sp_groups_ext  = toset([for m in values(module.naming.sp_memberships) : m.group if !contains(keys(module.naming.groups), m.group)])
  sp_members_ext = toset([for m in values(module.naming.sp_memberships) : m.sp if !contains(keys(module.naming.service_principals), m.sp)])
}

data "azuread_group" "ext" {
  for_each         = setunion(local.nesting_ext, local.sp_groups_ext)
  display_name     = module.naming.all_group_names[each.key]
  security_enabled = true
}

locals {
  group_ids = merge(
    { for k, g in azuread_group.this : k => g.object_id },
    { for k, g in data.azuread_group.ext : k => g.object_id },
  )
}

resource "azuread_group_member" "nesting" {
  for_each         = module.naming.nesting
  group_object_id  = local.group_ids[each.value.parent]
  member_object_id = local.group_ids[each.value.child]
}

# -----------------------------------------------------------------------------
# Test users (training only) - sign in as each persona to verify access.
# The users are shared; which groups they join is access (stack 25).
# -----------------------------------------------------------------------------
resource "random_password" "test_user" {
  for_each         = module.naming.test_users
  length           = 20
  special          = true
  override_special = "!#%*-_=+"
}

resource "azuread_user" "test" {
  for_each              = module.naming.test_users
  user_principal_name   = "${each.key}@${local.tenant_domain}"
  display_name          = each.value.display_name
  password              = random_password.test_user[each.key].result
  force_password_change = true
}

# -----------------------------------------------------------------------------
# Service principals: per-domain deployers, vault loaders, extras.
# -----------------------------------------------------------------------------
resource "azuread_application" "sp" {
  for_each     = module.naming.service_principals
  display_name = each.value.display_name
  owners       = [local.tf_owner]
  notes        = each.value.description
}

resource "azuread_service_principal" "sp" {
  for_each  = module.naming.service_principals
  client_id = azuread_application.sp[each.key].client_id
  owners    = [local.tf_owner]
}

locals {
  sp_subjects = { for item in flatten([
    for sk, s in module.naming.service_principals : [
      for subj in s.github_subjects : { key = "${sk}|${subj}", sp = sk, subject = subj }
    ]
  ]) : item.key => item }
}

# GitHub OIDC trust: repo:<org>/<repo>:environment:<env>. No secrets exist.
resource "azuread_application_federated_identity_credential" "sp" {
  for_each       = local.sp_subjects
  application_id = azuread_application.sp[each.value.sp].id
  display_name   = substr(replace(replace(each.value.subject, "/[^A-Za-z0-9-]/", "-"), "--", "-"), 0, 120)
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = each.value.subject
}

# An SP owned by another scope is found by its display name.
data "azuread_service_principal" "ext" {
  for_each     = local.sp_members_ext
  display_name = module.naming.all_service_principal_names[each.key]
}

resource "azuread_group_member" "sp" {
  for_each        = module.naming.sp_memberships
  group_object_id = local.group_ids[each.value.group]
  member_object_id = contains(keys(module.naming.service_principals), each.value.sp) ? (
    azuread_service_principal.sp[each.value.sp].object_id
  ) : data.azuread_service_principal.ext[each.value.sp].object_id
}

# The Terraform identities (the shared one and one per environment, created by bootstrap/) are
# metastore admins through piq-metastore-admins (RUNBOOK Phase 4 sets that group as metastore
# admin). Shared scope only.
locals {
  terraform_sps = var.scope == "shared" ? toset(concat(
    ["sp-${module.naming.prefix}-terraform"],
    [for e in module.naming.env_keys : "sp-${module.naming.prefix}-terraform-${e}"],
  )) : toset([])
}

data "azuread_service_principal" "terraform" {
  for_each     = local.terraform_sps
  display_name = each.value
}

resource "azuread_group_member" "terraform_metastore_admin" {
  for_each         = local.terraform_sps
  group_object_id  = azuread_group.this["platform:metastore-admins"].object_id
  member_object_id = data.azuread_service_principal.terraform[each.key].object_id
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "groups" {
  value = { for k, g in azuread_group.this : k => { name = g.display_name, object_id = g.object_id } }
}

output "service_principals" {
  value = { for k, s in azuread_service_principal.sp : k => {
    display_name = s.display_name
    client_id    = s.client_id
    object_id    = s.object_id
  } }
}

output "missing_consumer_leads" {
  description = "Consumer leads not found in Entra; their groups are owned by Terraform only"
  value       = [for l in local.leads : l if !contains(keys(local.lead_ids), l)]
}

output "test_user_credentials" {
  description = "TRAINING ONLY. terraform output -json test_user_credentials"
  sensitive   = true
  value       = { for k, u in azuread_user.test : u.user_principal_name => random_password.test_user[k].result }
}
