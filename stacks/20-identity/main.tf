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

module "naming" {
  source     = "../../modules/naming"
  config_dir = "${path.root}/../../config"
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

# Group-in-group membership: personas into roles, consumers into products,
# approved groups into SARs. Child is a member of parent.
resource "azuread_group_member" "nesting" {
  for_each         = module.naming.nesting
  group_object_id  = azuread_group.this[each.value.parent].object_id
  member_object_id = azuread_group.this[each.value.child].object_id
}

# -----------------------------------------------------------------------------
# People: persona members, domain admins, sandbox users, experiment members.
# -----------------------------------------------------------------------------
data "azuread_user" "member" {
  for_each            = toset(distinct([for m in values(module.naming.user_memberships) : m.upn]))
  user_principal_name = each.value
}

resource "azuread_group_member" "user" {
  for_each         = module.naming.user_memberships
  group_object_id  = azuread_group.this[each.value.group].object_id
  member_object_id = data.azuread_user.member[each.value.upn].object_id
}

# -----------------------------------------------------------------------------
# Test users (training only) - sign in as each persona to verify access.
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

resource "azuread_group_member" "test_user" {
  for_each         = module.naming.test_user_memberships
  group_object_id  = azuread_group.this[each.value.group].object_id
  member_object_id = azuread_user.test[each.value.user].object_id
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

resource "azuread_group_member" "sp" {
  for_each         = module.naming.sp_memberships
  group_object_id  = azuread_group.this[each.value.group].object_id
  member_object_id = azuread_service_principal.sp[each.value.sp].object_id
}

# The Terraform SP is a metastore admin through piq-metastore-admins
# (RUNBOOK Phase 4 sets that group as metastore admin).
data "azuread_service_principal" "terraform" {
  display_name = "sp-${module.naming.prefix}-terraform"
}

resource "azuread_group_member" "terraform_metastore_admin" {
  group_object_id  = azuread_group.this["platform:metastore-admins"].object_id
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

output "missing_consumer_leads" {
  description = "Consumer leads not found in Entra; their groups are owned by Terraform only"
  value       = [for l in local.leads : l if !contains(keys(local.lead_ids), l)]
}

output "test_user_credentials" {
  description = "TRAINING ONLY. terraform output -json test_user_credentials"
  sensitive   = true
  value       = { for k, u in azuread_user.test : u.user_principal_name => random_password.test_user[k].result }
}
