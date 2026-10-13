# =============================================================================
# 20-identity - Microsoft Entra ID: groups, nesting, service principals.
#
# Entra is the single source of truth for identity. Databricks automatic
# identity management (AIM) makes these groups and principals visible in the
# account without SCIM. Group membership can ONLY be changed here (or in Entra);
# Databricks shows AIM-managed groups as "External" and read-only.
# =============================================================================

module "naming" {
  source     = "../../modules/naming"
  config_dir = "${path.root}/../../config"
}

data "azuread_client_config" "current" {}
data "azuread_domains" "initial" { only_initial = true }

locals {
  owners        = [data.azuread_client_config.current.object_id]
  tenant_domain = data.azuread_domains.initial.domains[0].domain_name
  test_users    = module.naming.test_users.enabled ? module.naming.test_users.users : {}
}

# -----------------------------------------------------------------------------
# Groups: functional (env x domain x role), platform, persona
# -----------------------------------------------------------------------------
resource "azuread_group" "this" {
  for_each                = module.naming.all_groups
  display_name            = each.value.name
  description             = "${each.value.description} | managed by terraform"
  security_enabled        = true
  owners                  = local.owners
  prevent_duplicate_names = true
}

# Persona groups are nested INTO functional/platform groups.
resource "azuread_group_member" "persona_nesting" {
  for_each         = module.naming.persona_nesting
  group_object_id  = azuread_group.this[each.value.parent].object_id
  member_object_id = azuread_group.this[each.value.persona].object_id
}

# -----------------------------------------------------------------------------
# Test users (training only) - sign in as each persona to verify access.
# -----------------------------------------------------------------------------
resource "random_password" "test_user" {
  for_each         = local.test_users
  length           = 20
  special          = true
  override_special = "!#%*-_=+"
}

resource "azuread_user" "test" {
  for_each              = local.test_users
  user_principal_name   = "${each.key}@${local.tenant_domain}"
  display_name          = each.value.display_name
  password              = random_password.test_user[each.key].result
  force_password_change = true
}

resource "azuread_group_member" "test_persona" {
  for_each         = local.test_users
  group_object_id  = azuread_group.this["pe:${each.value.persona}"].object_id
  member_object_id = azuread_user.test[each.key].object_id
}

# -----------------------------------------------------------------------------
# Real users: persona members, sandbox users, experiment members (by UPN).
# -----------------------------------------------------------------------------
locals {
  persona_member_pairs = { for item in flatten([
    for pk, p in module.naming.persona_groups : [for upn in p.members : { key = "${pk}|${upn}", persona = pk, upn = upn }]
  ]) : item.key => item }

  sandbox_upns    = [for u in module.naming.sandbox_users : u.upn]
  experiment_upns = distinct(flatten([for e in module.naming.experiments : e.members]))
  all_upns        = distinct(concat([for v in values(local.persona_member_pairs) : v.upn], local.sandbox_upns, local.experiment_upns))
}

data "azuread_user" "member" {
  for_each            = toset(local.all_upns)
  user_principal_name = each.value
}

resource "azuread_group_member" "persona_member" {
  for_each         = local.persona_member_pairs
  group_object_id  = azuread_group.this["pe:${each.value.persona}"].object_id
  member_object_id = data.azuread_user.member[each.value.upn].object_id
}

resource "azuread_group_member" "sandbox_user" {
  for_each         = toset(local.sandbox_upns)
  group_object_id  = azuread_group.this["pl:sandbox-users"].object_id
  member_object_id = data.azuread_user.member[each.value].object_id
}

resource "azuread_group_member" "experimenter" {
  for_each         = toset(local.experiment_upns)
  group_object_id  = azuread_group.this["pl:prd-experimenters"].object_id
  member_object_id = data.azuread_user.member[each.value].object_id
}

# -----------------------------------------------------------------------------
# Service principals (non-human identities)
# -----------------------------------------------------------------------------
resource "azuread_application" "sp" {
  for_each     = module.naming.service_principals
  display_name = each.value.display_name
  owners       = local.owners
  notes        = each.value.description
}

resource "azuread_service_principal" "sp" {
  for_each  = module.naming.service_principals
  client_id = azuread_application.sp[each.key].client_id
  owners    = local.owners
}

# GitHub OIDC trust for deployer SPs: repo:<org>/<repo>:environment:<env>
locals {
  sp_subjects = { for item in flatten([
    for sk, s in module.naming.service_principals : [
      for subj in s.github_subjects : { key = "${sk}|${subj}", sp = sk, subject = subj }
    ]
  ]) : item.key => item }
}

resource "azuread_application_federated_identity_credential" "sp" {
  for_each       = local.sp_subjects
  application_id = azuread_application.sp[each.value.sp].id
  display_name   = substr(replace(replace(each.value.subject, "/[^A-Za-z0-9-]/", "-"), "--", "-"), 0, 120)
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = each.value.subject
}

resource "azuread_group_member" "sp" {
  for_each         = module.naming.sp_memberships
  group_object_id  = azuread_group.this[each.value.group].object_id
  member_object_id = azuread_service_principal.sp[each.value.sp].object_id
}

# The Terraform SP must be a metastore admin (RUNBOOK Phase 4 assigns the
# metastore admin role to the piq-metastore-admins group).
data "azuread_service_principal" "terraform" {
  display_name = "sp-${module.naming.prefix}-terraform"
}

resource "azuread_group_member" "terraform_metastore_admin" {
  group_object_id  = azuread_group.this["pl:metastore-admins"].object_id
  member_object_id = data.azuread_service_principal.terraform.object_id
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

output "users" {
  description = "UPN -> Entra object id for users referenced by grants"
  value = merge(
    { for upn, u in data.azuread_user.member : upn => u.object_id },
    { for k, u in azuread_user.test : u.user_principal_name => u.object_id },
  )
}

output "test_user_credentials" {
  description = "TRAINING ONLY. terraform output -json test_user_credentials"
  sensitive   = true
  value       = { for k, u in azuread_user.test : u.user_principal_name => random_password.test_user[k].result }
}
