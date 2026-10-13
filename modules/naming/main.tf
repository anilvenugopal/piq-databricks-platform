# =============================================================================
# modules/naming - the single source of derived names and access mappings.
#
# Every stack calls this module. It has no providers and creates nothing; it
# reads config/*.yaml and returns maps. Keeping all naming logic here means a
# group, catalog or grant is spelled the same way in every stack.
# =============================================================================

variable "config_dir" {
  description = "Path to the repo's config/ directory"
  type        = string
}

locals {
  platform  = yamldecode(file("${var.config_dir}/platform.yaml"))
  domains   = yamldecode(file("${var.config_dir}/domains.yaml"))
  matrix    = yamldecode(file("${var.config_dir}/access_matrix.yaml"))
  wsobj     = yamldecode(file("${var.config_dir}/workspace_objects.yaml"))
  personas  = yamldecode(file("${var.config_dir}/personas.yaml"))
  sps       = yamldecode(file("${var.config_dir}/service_principals.yaml"))
  tags      = yamldecode(file("${var.config_dir}/governed_tags.yaml"))
  cost      = yamldecode(file("${var.config_dir}/cost.yaml"))
  sandbox   = yamldecode(file("${var.config_dir}/sandbox_users.yaml"))
  exps      = yamldecode(file("${var.config_dir}/experiments.yaml"))
  testusers = yamldecode(file("${var.config_dir}/test_users.yaml"))

  prefix       = local.platform.prefix
  environments = local.platform.environments
  env_keys     = sort(keys(local.environments))
  data_domains = local.domains.domains
  domain_keys  = sort(keys(local.data_domains))
  roles        = local.matrix.roles

  # ---------------------------------------------------------------------------
  # Catalogs: {env}_{domain} for data domains, plus {env}_sandbox and {env}_platform.
  # Storage container per catalog = the domain key (or sandbox/platform).
  # ---------------------------------------------------------------------------
  catalogs = merge(
    { for pair in setproduct(local.env_keys, local.domain_keys) :
      "${pair[0]}-${pair[1]}" => {
        env       = pair[0], domain = pair[1], kind = "data"
        name      = "${pair[0]}_${pair[1]}"
        container = pair[1]
        comment   = local.data_domains[pair[1]].description
      }
    },
    { for env in local.env_keys :
      "${env}-sandbox" => {
        env     = env, domain = "sandbox", kind = "sandbox", name = "${env}_sandbox", container = "sandbox"
        comment = env == "dev" ? "Personal sandboxes u_<user>; dev data only" : "Approved experiments exp_<name>"
      }
    },
    { for env in local.env_keys :
      "${env}-platform" => {
        env     = env, domain = "platform", kind = "platform", name = "${env}_platform", container = "platform"
        comment = "Platform governance functions, audit, monitoring and observability views"
      }
    },
  )

  storage_containers = distinct(concat(local.domain_keys, ["sandbox", "platform"]))

  # ---------------------------------------------------------------------------
  # Groups. Every group is an Entra security group; Databricks sees them through
  # automatic identity management (AIM). Keys are stable identifiers; names are
  # what humans and Unity Catalog see.
  # ---------------------------------------------------------------------------
  functional_groups = { for t in setproduct(local.env_keys, local.domain_keys, local.roles) :
    "${t[0]}-${t[1]}-${t[2]}" => {
      name        = "${local.prefix}-${t[0]}-${t[1]}-${t[2]}"
      env         = t[0]
      domain      = t[1]
      role        = t[2]
      description = "${upper(t[2])} for ${t[1]} in ${t[0]}"
    }
  }

  platform_groups = { for k, g in local.personas.platform_groups :
    k => {
      name        = "${local.prefix}-${k}"
      description = g.description
      workspaces  = g.workspaces
    }
  }

  persona_groups = { for k, p in local.personas.personas :
    k => {
      name        = "${local.prefix}-persona-${k}"
      description = p.description
      members     = try(p.members, [])
    }
  }

  all_groups = merge(
    { for k, g in local.functional_groups : "fn:${k}" => { name = g.name, description = g.description } },
    { for k, g in local.platform_groups : "pl:${k}" => { name = g.name, description = g.description } },
    { for k, g in local.persona_groups : "pe:${k}" => { name = g.name, description = g.description } },
  )

  # Expand "<env>:<domain|*>:<role>" or "<platform-group>" into all_groups keys.
  expand_ref = { for ref in distinct(concat(
    flatten([for p in values(local.personas.personas) : p.member_of]),
    flatten([for s in values(local.sps.service_principals) : s.member_of]),
    )) :
    ref => length(split(":", ref)) == 3 ? [
      for d in(split(":", ref)[1] == "*" ? local.domain_keys : [split(":", ref)[1]]) :
      "fn:${split(":", ref)[0]}-${d}-${split(":", ref)[2]}"
    ] : ["pl:${ref}"]
  }

  # persona group -> parent group nesting (persona is a MEMBER of the parent)
  persona_nesting = { for item in flatten([
    for pk, p in local.personas.personas : [
      for ref in p.member_of : [
        for gk in local.expand_ref[ref] : { key = "${pk}|${gk}", persona = "pe:${pk}", parent = gk }
      ]
    ]
  ]) : item.key => item }

  # ---------------------------------------------------------------------------
  # Service principals
  # ---------------------------------------------------------------------------
  service_principals = { for k, s in local.sps.service_principals :
    k => {
      display_name = "sp-${local.prefix}-${k}"
      description  = s.description
      workspaces   = s.workspaces
      member_of    = distinct(flatten([for ref in s.member_of : local.expand_ref[ref]]))
      github_subjects = [for g in s.github_subjects :
        "repo:${local.platform.github.org}/${g.repo}:environment:${g.environment}"
      ]
    }
  }

  sp_memberships = { for item in flatten([
    for sk, s in local.service_principals : [
      for gk in s.member_of : { key = "${sk}|${gk}", sp = sk, group = gk }
    ]
  ]) : item.key => item }

  # ---------------------------------------------------------------------------
  # Workspace assignments: which group gets USER/ADMIN on which env workspace.
  # Persona groups are NOT assigned; their nested functional groups are.
  # ---------------------------------------------------------------------------
  group_workspace_assignments = merge(
    { for k, g in local.functional_groups :
      "fn:${k}|${g.env}" => { group = "fn:${k}", env = g.env, permission = "USER" }
    },
    merge([for k, g in local.platform_groups : {
      for env, perm in g.workspaces : "pl:${k}|${env}" => { group = "pl:${k}", env = env, permission = perm }
    }]...),
  )

  sp_workspace_assignments = merge([for k, s in local.service_principals : {
    for env, perm in s.workspaces : "${k}|${env}" => { sp = k, env = env, permission = perm }
  }]...)

  # ---------------------------------------------------------------------------
  # Unity Catalog grants for data-domain catalogs.
  # ---------------------------------------------------------------------------
  catalog_grants = { for ck, c in local.catalogs : ck => (
    c.kind == "data" ? [
      for role in local.roles : {
        principal  = local.functional_groups["${c.env}-${c.domain}-${role}"].name
        privileges = role == "dbadmin" ? distinct(concat(local.matrix.catalog.every_role, local.matrix.catalog.dbadmin)) : local.matrix.catalog.every_role
      }
      ] : c.kind == "sandbox" ? [
      {
        principal  = local.platform_groups[c.env == "dev" ? "sandbox-users" : "prd-experimenters"].name
        privileges = ["USE_CATALOG", "BROWSE"]
      },
      { principal = local.platform_groups["governance-admins"].name, privileges = ["USE_CATALOG", "BROWSE", "MANAGE"] },
      ] : [
      { principal = "account users", privileges = ["USE_CATALOG"] },
      { principal = local.platform_groups["governance-admins"].name, privileges = ["ALL_PRIVILEGES", "MANAGE"] },
      { principal = local.platform_groups["platform-monitoring"].name, privileges = ["USE_CATALOG", "BROWSE"] },
    ]
  ) }

  data_schemas = { for t in setproduct(keys({ for k, c in local.catalogs : k => c if c.kind == "data" }), keys(local.domains.schemas)) :
    "${t[0]}.${t[1]}" => {
      catalog_key = t[0]
      catalog     = local.catalogs[t[0]].name
      env         = local.catalogs[t[0]].env
      domain      = local.catalogs[t[0]].domain
      name        = t[1]
      layer       = local.domains.schemas[t[1]].layer
      comment     = local.domains.schemas[t[1]].comment
      volumes     = try(local.domains.schemas[t[1]].volumes, [])
      grants = [
        for role, bundle in try(local.matrix.matrix[t[1]], {}) : {
          principal  = local.functional_groups["${local.catalogs[t[0]].env}-${local.catalogs[t[0]].domain}-${role}"].name
          privileges = local.matrix.bundles[bundle]
        }
      ]
    }
  }

  platform_schemas = { for t in setproduct(local.env_keys, ["governance", "audit", "monitoring", "observability"]) :
    "${t[0]}-platform.${t[1]}" => {
      catalog_key = "${t[0]}-platform"
      catalog     = "${t[0]}_platform"
      env         = t[0]
      domain      = "platform"
      name        = t[1]
      layer       = "PLATFORM"
      comment     = "Platform ${t[1]}"
      volumes     = []
      grants = t[1] == "governance" ? [
        { principal = "account users", privileges = ["USE_SCHEMA", "EXECUTE"] },
        ] : [
        { principal = local.platform_groups["platform-monitoring"].name, privileges = ["USE_SCHEMA", "SELECT"] },
      ]
    }
  }

  sandbox_user_schemas = { for u in try(local.sandbox.users, []) :
    "dev-sandbox.u_${replace(lower(split("@", u.upn)[0]), "/[^a-z0-9]/", "_")}" => {
      catalog_key = "dev-sandbox"
      catalog     = "dev_sandbox"
      env         = "dev"
      domain      = "sandbox"
      name        = "u_${replace(lower(split("@", u.upn)[0]), "/[^a-z0-9]/", "_")}"
      layer       = "SCRATCH"
      comment     = "Personal sandbox for ${u.upn} (${try(u.requested_via, "n/a")})"
      volumes     = []
      grants      = [{ principal = u.upn, privileges = ["ALL_PRIVILEGES"] }]
    }
  }

  experiment_schemas = { for e in try(local.exps.experiments, []) :
    "prd-sandbox.exp_${lower(e.name)}" => {
      catalog_key = "prd-sandbox"
      catalog     = "prd_sandbox"
      env         = "prd"
      domain      = "sandbox"
      name        = "exp_${lower(e.name)}"
      layer       = "SCRATCH"
      comment     = "${e.description} | approved by ${e.approved_by} | ${e.ticket} | expires ${try(e.expires, "n/a")}"
      volumes     = []
      grants      = [for m in e.members : { principal = m, privileges = ["ALL_PRIVILEGES"] }]
    }
  }

  all_schemas = merge(local.data_schemas, local.platform_schemas, local.sandbox_user_schemas, local.experiment_schemas)

  volumes = { for item in flatten([
    for sk, s in local.all_schemas : [
      for v in s.volumes : { key = "${sk}.${v}", catalog = s.catalog, schema = s.name, name = v, env = s.env, catalog_key = s.catalog_key }
    ]
  ]) : item.key => item }

  # Users referenced by sandbox/experiment grants (must exist in the account).
  granted_users = distinct(concat(
    [for u in try(local.sandbox.users, []) : u.upn],
    flatten([for e in try(local.exps.experiments, []) : e.members]),
  ))

  # ---------------------------------------------------------------------------
  # Tags
  # ---------------------------------------------------------------------------
  tag_assigner_groups = { for tk, t in local.tags.tags : tk => distinct(flatten([
    for a in t.assigners : startswith(a, "role:") ? [
      for k, g in local.functional_groups : g.name if g.role == trimprefix(a, "role:")
    ] : [local.platform_groups[a].name]
  ])) }

  # ---------------------------------------------------------------------------
  # Validation: humans must never be able to write to prd through producer groups.
  # ---------------------------------------------------------------------------
  prd_sp_only_violations = [
    for item in values(local.persona_nesting) : item.key
    if startswith(item.parent, "fn:prd-") && contains(local.matrix.service_principal_only_in_prd, element(split("-", item.parent), length(split("-", item.parent)) - 1))
  ]
}

output "prefix" { value = local.prefix }
output "platform" { value = local.platform }
output "environments" { value = local.environments }
output "env_keys" { value = local.env_keys }
output "data_domains" { value = local.data_domains }
output "domain_keys" { value = local.domain_keys }
output "roles" { value = local.roles }
output "catalogs" { value = local.catalogs }
output "storage_containers" { value = local.storage_containers }
output "functional_groups" { value = local.functional_groups }
output "platform_groups" { value = local.platform_groups }
output "persona_groups" { value = local.persona_groups }
output "all_groups" { value = local.all_groups }
output "persona_nesting" { value = local.persona_nesting }
output "service_principals" { value = local.service_principals }
output "sp_memberships" { value = local.sp_memberships }
output "group_workspace_assignments" { value = local.group_workspace_assignments }
output "sp_workspace_assignments" { value = local.sp_workspace_assignments }
output "catalog_grants" { value = local.catalog_grants }
output "schemas" { value = local.all_schemas }
output "volumes" { value = local.volumes }
output "granted_users" { value = local.granted_users }
output "governed_tags" { value = local.tags }
output "tag_assigner_groups" { value = local.tag_assigner_groups }
output "workspace_objects" { value = local.wsobj }
output "cost" { value = local.cost }
output "test_users" { value = local.testusers }
output "sandbox_users" { value = try(local.sandbox.users, []) }
output "experiments" { value = try(local.exps.experiments, []) }
output "matrix" { value = local.matrix }

output "state_backend" {
  description = "Backend settings for terraform_remote_state lookups"
  value = {
    resource_group_name  = local.platform.state.resource_group
    storage_account_name = local.platform.state.storage_account
    container_name       = local.platform.state.container
    use_azuread_auth     = true
  }
}

output "validation" {
  value = "ok"
  precondition {
    condition     = length(local.prd_sp_only_violations) == 0
    error_message = "Personas may not be nested into prd producer groups (service principals only): ${join(", ", local.prd_sp_only_violations)}"
  }
  precondition {
    condition     = length(setintersection(local.domain_keys, local.domains.reserved)) == 0
    error_message = "A domain key uses a reserved name: ${join(", ", local.domains.reserved)}"
  }
}
