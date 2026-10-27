# =============================================================================
# modules/naming - the single source of derived names, groups and grants.
#
# Every stack calls this module. It has no providers and creates nothing: it
# reads config/ and returns maps. Keeping all naming logic here means a group,
# catalog or grant is spelled the same way in every stack.
#
# Naming rule: the environment appears only in names whose scope spans
# environments (catalogs, Entra groups, service principals, usage policies).
# Schemas and workspace objects (warehouses, app spaces) carry none.
#
# Scopes: every group, catalog, schema, grant, policy, warehouse and service
# principal belongs to exactly ONE scope (its `sid`):
#   shared               account-wide, spans environments        sid "shared"
#   env                  one environment's infrastructure        sid "<env>/env"
#   domain:<name>        one domain in one environment           sid "<env>/domain:<name>"
#   access               people and approvals in one environment sid "<env>/access"
# The whole module is always computed in full, so names can be referenced across
# scopes. The `scope` and `environment` variables only filter the OUTPUTS to one
# scope, which is what each Terraform run applies. With neither set, every output
# is complete (used by tests, validators and tooling).
# =============================================================================

variable "config_dir" {
  description = "Path to the repo's config/ directory"
  type        = string
}

variable "environment" {
  description = "Filter outputs to this environment (required unless scope is shared or unset)"
  type        = string
  default     = null
}

variable "scope" {
  description = "Filter outputs to one scope: shared | env | access | domain:<name>. Unset = everything"
  type        = string
  default     = null
}

locals {
  # ---------------------------------------------------------------------------
  # Load configuration
  # ---------------------------------------------------------------------------
  platform  = yamldecode(file("${var.config_dir}/platform.yaml"))
  dcfg      = yamldecode(file("${var.config_dir}/domains.yaml"))
  matrix    = yamldecode(file("${var.config_dir}/access_matrix.yaml"))
  wsobj     = yamldecode(file("${var.config_dir}/workspace_objects.yaml"))
  pcfg      = yamldecode(file("${var.config_dir}/personas.yaml"))
  spcfg     = yamldecode(file("${var.config_dir}/service_principals.yaml"))
  tagcfg    = yamldecode(file("${var.config_dir}/governed_tags.yaml"))
  sarcfg    = yamldecode(file("${var.config_dir}/sars.yaml"))
  cost      = yamldecode(file("${var.config_dir}/cost.yaml"))
  testusers = yamldecode(file("${var.config_dir}/test_users.yaml"))

  product_files  = sort(tolist(fileset("${var.config_dir}/products", "*.yaml")))
  consumer_files = sort(tolist(fileset("${var.config_dir}/consumers", "*.yaml")))

  product_docs = { for f in local.product_files :
    trimsuffix(f, ".yaml") => try(yamldecode(file("${var.config_dir}/products/${f}")).products, {})
  }
  product_name_list = flatten([for d, ps in local.product_docs : keys(ps)])

  # product name -> definition, with its owning domain (= file name)
  products = merge([for d, ps in local.product_docs : {
    for name, p in ps : name => {
      domain      = d
      type        = p.type
      description = try(p.description, "")
      contract    = try(p.contract, "")
      status      = try(p.status, "draft")
    }
  }]...)

  consumers = { for f in local.consumer_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${var.config_dir}/consumers/${f}"))
  }

  prefix        = local.platform.prefix
  environments  = local.platform.environments
  env_keys      = sort(keys(local.environments))
  domains       = local.dcfg.domains
  domain_keys   = sort(keys(local.domains))
  consumer_keys = sort(keys(local.consumers))
  product_keys  = sort(keys(local.products))
  vault         = local.dcfg.vault
  sars          = local.sarcfg.sars
  masks         = local.tagcfg.masks

  # ---------------------------------------------------------------------------
  # Environment tiers. Rules depend on the tier, never on the environment name:
  # exactly one environment is "prod"; every other one is "nonprod".
  # ---------------------------------------------------------------------------
  env_tier      = { for e in local.env_keys : e => try(local.environments[e].tier, "") }
  prod_envs     = [for e in local.env_keys : e if local.env_tier[e] == "prod"]
  nonprod_envs  = [for e in local.env_keys : e if local.env_tier[e] == "nonprod"]
  prod_env      = try(local.prod_envs[0], "")
  has_anon_path = length(local.prod_envs) == 1 && length(local.nonprod_envs) > 0

  hy = { for k in concat(local.domain_keys, local.consumer_keys, local.product_keys, keys(local.sars)) : k => replace(k, "_", "-") }

  # ---------------------------------------------------------------------------
  # Entitlements: who is in which group, which access requests are approved.
  # One folder per environment (config/entitlements/<env>/). Only stack 25-access
  # turns these into memberships. A missing file means "nothing".
  # ---------------------------------------------------------------------------
  ent_files = ["personas", "product_access", "sars", "sandboxes", "experiments", "admins"]
  ent = { for e in local.env_keys : e => {
    for f in local.ent_files : f => try(yamldecode(file("${var.config_dir}/entitlements/${e}/${f}.yaml")), {})
  } }

  # ---------------------------------------------------------------------------
  # Per-domain shape and access: the standard plus what a domain adds.
  #   domain_shape/<d>.yaml   (domain team)            schemas add/remove, roles, personas
  #   domain_access/<d>.yaml  (platform + governance)  schema access, warehouse, persona access
  # ---------------------------------------------------------------------------
  dshape = { for d in local.domain_keys : d => try(yamldecode(file("${var.config_dir}/domain_shape/${d}.yaml")), {}) }
  dacc   = { for d in local.domain_keys : d => try(yamldecode(file("${var.config_dir}/domain_access/${d}.yaml")), {}) }

  extra_roles        = { for d in local.domain_keys : d => try(local.dshape[d].roles, {}) }
  domain_roles       = { for d in local.domain_keys : d => distinct(concat(local.matrix.roles, sort(keys(local.extra_roles[d])))) }
  domain_local_roles = { for d in local.domain_keys : d => [for r in local.domain_roles[d] : r if r != "dbadmin"] }
  sp_only_roles = { for d in local.domain_keys : d => concat(
    local.matrix.service_principal_only_in_prod,
    [for r, c in local.extra_roles[d] : r if try(c.service_principal_only, false)],
  ) }
  all_roles = distinct(flatten(values(local.domain_roles)))

  # schema name -> definition, per domain: the standard minus `remove`, plus `add`
  domain_schema_defs = { for d in local.domain_keys : d => merge(
    { for sn, sc in local.dcfg.schemas : sn => sc if !contains(try(local.dshape[d].schemas.remove, []), sn) },
    try(local.dshape[d].schemas.add, {}),
  ) }

  # ---------------------------------------------------------------------------
  # Groups. Every group is an Entra security group, visible in Databricks
  # through automatic identity management. Every value has the same shape.
  #   kind: domain | writer | vault | product | consumer | sar | platform | persona
  #   lead: Entra owner for consumer groups (membership managed by the lead)
  #   sid:  the scope that owns the group (see header)
  # ---------------------------------------------------------------------------
  domain_groups = { for t in flatten([
    for e in local.env_keys : [for d in local.domain_keys : [for r in local.domain_roles[d] : { e = e, d = d, r = r }]]
    ]) : "${t.e}:${t.d}:${t.r}" => {
    name        = "${local.prefix}-${t.e}-${local.hy[t.d]}-${t.r}", kind = "domain", env = t.e, owner = t.d, role = t.r, lead = ""
    description = "${t.r} role of the ${t.d} domain in ${t.e}"
    scope       = "domain:${t.d}", sid = "${t.e}/domain:${t.d}"
  } }

  writer_groups = { for p in setproduct(local.env_keys, local.domain_keys) :
    "writer:${p[0]}:${p[1]}" => {
      name        = "${local.prefix}-${p[0]}-${local.hy[p[1]]}-writer", kind = "writer", env = p[0], owner = p[1], role = "writer", lead = ""
      description = "Data writers of the ${p[1]} domain in ${p[0]} (deploy service principal only); exempt from masks"
      scope       = "domain:${p[1]}", sid = "${p[0]}/domain:${p[1]}"
    }
  }

  vault_groups = { for p in setproduct(local.env_keys, ["engineer", "writer"]) :
    "vault:${p[0]}:${p[1]}" => {
      name        = "${local.prefix}-${p[0]}-vault-${p[1]}", kind = "vault", env = p[0], owner = "vault", role = p[1], lead = ""
      description = p[1] == "writer" ? "Vault loader in ${p[0]} (service principal only); sole writer to ${p[0]}_vault" : "Vault engineers in ${p[0]}"
      scope       = "env", sid = "${p[0]}/env"
    }
  }

  product_groups = { for p in setproduct(local.env_keys, local.product_keys) :
    "product:${p[0]}:${p[1]}" => {
      name        = "${local.prefix}-${p[0]}-product-${local.hy[p[1]]}", kind = "product", env = p[0], owner = local.products[p[1]].domain, role = p[1], lead = ""
      description = "Readers of the ${p[1]} product (${local.products[p[1]].domain}) in ${p[0]}"
      scope       = "domain:${local.products[p[1]].domain}", sid = "${p[0]}/domain:${local.products[p[1]].domain}"
    }
  }

  consumer_groups = { for item in flatten([
    for ck, c in local.consumers : [for r in c.roles : { ck = ck, r = r, lead = c.lead }]
    ]) : "consumer:${item.ck}:${item.r}" => {
    name        = "${local.prefix}-${local.prod_env}-${local.hy[item.ck]}-${item.r}", kind = "consumer", env = local.prod_env, owner = item.ck, role = item.r, lead = item.lead
    description = "${item.r} role of the ${item.ck} consumer domain; membership managed by ${item.lead}"
    scope       = "env", sid = "${local.prod_env}/env"
  } }

  sar_groups = { for p in setproduct(local.env_keys, keys(local.sars)) :
    "sar:${p[0]}:${p[1]}" => {
      name        = "${local.prefix}-${p[0]}-sar-${local.hy[p[1]]}", kind = "sar", env = p[0], owner = "governance", role = p[1], lead = ""
      description = "Sensitive access role ${p[1]} in ${p[0]}: ${local.sars[p[1]].description}"
      scope       = "env", sid = "${p[0]}/env"
    }
  }

  # A platform group assigned to exactly one workspace belongs to that environment;
  # one assigned to several is shared. <env>-workspace-admins is generated per environment.
  pg_env_of = { for k, g in local.pcfg.platform_groups : k => length(keys(g.workspaces)) == 1 ? keys(g.workspaces)[0] : "" }
  pg_workspaces = merge(
    { for k, g in local.pcfg.platform_groups : k => keys(g.workspaces) },
    { for e in local.env_keys : "${e}-workspace-admins" => [e] },
  )

  platform_groups = merge(
    { for k, g in local.pcfg.platform_groups :
      "platform:${k}" => {
        name        = "${local.prefix}-${k}", kind = "platform", env = local.pg_env_of[k], owner = "platform", role = k, lead = ""
        description = g.description
        scope       = local.pg_env_of[k] == "" ? "shared" : "env", sid = local.pg_env_of[k] == "" ? "shared" : "${local.pg_env_of[k]}/env"
      }
    },
    { for e in local.env_keys :
      "platform:${e}-workspace-admins" => {
        name        = "${local.prefix}-${e}-workspace-admins", kind = "platform", env = e, owner = "platform", role = "${e}-workspace-admins", lead = ""
        description = "Workspace admins for ${e}"
        scope       = "env", sid = "${e}/env"
      }
    },
  )

  # Personas: one group per persona per environment. A global persona (personas.yaml) has the
  # same shape everywhere; its access differs per environment. A domain persona
  # (domain_shape/<d>.yaml) belongs to that domain.
  persona_list = concat(
    flatten([for e in local.env_keys : [for k, p in local.pcfg.personas : {
      key = "persona:${e}:${k}", env = e, name = k, domain = "", description = p.description, access = try(p.access[e], [])
    }]]),
    flatten([for e in local.env_keys : [for d in local.domain_keys : [for k, p in try(local.dshape[d].personas, {}) : {
      key = "persona:${e}:${d}:${k}", env = e, name = k, domain = d, description = p.description, access = try(local.dacc[d].personas[k].access[e], [])
    }]]]),
  )
  persona_defs = { for p in local.persona_list : p.key => p }

  persona_groups = { for k, p in local.persona_defs :
    k => {
      name        = p.domain == "" ? "${local.prefix}-${p.env}-persona-${p.name}" : "${local.prefix}-${p.env}-persona-${local.hy[p.domain]}-${p.name}"
      kind        = "persona", env = p.env, owner = p.domain == "" ? "persona" : p.domain, role = p.name, lead = ""
      description = p.description
      scope       = p.domain == "" ? "env" : "domain:${p.domain}", sid = p.domain == "" ? "${p.env}/env" : "${p.env}/domain:${p.domain}"
    }
  }

  groups = merge(
    local.domain_groups, local.writer_groups, local.vault_groups, local.product_groups,
    local.consumer_groups, local.sar_groups, local.platform_groups, local.persona_groups,
  )

  gname = { for k, g in local.groups : k => g.name }

  # ---------------------------------------------------------------------------
  # Group references used in personas, SPs, SARs and test users:
  #   "<env>:<domain|*>:<role>"  "vault:<env>:<role>"  "consumer:<c>:<role>"
  #   "persona:<env>:<name>"     "<platform-key>"
  # A "*" domain means every domain that defines the role.
  # ---------------------------------------------------------------------------
  all_refs = distinct(concat(
    flatten([for p in values(local.persona_defs) : p.access]),
    flatten([for s in values(local.spcfg.service_principals) : s.member_of]),
    flatten([for e in local.env_keys : flatten(values(try(local.ent[e].sars.members, {})))]),
    flatten([for u in values(try(local.testusers.users, {})) : u.member_of]),
  ))

  ref_targets = { for ref in local.all_refs : ref => (
    length(split(":", ref)) == 1 ? ["platform:${ref}"] :
    contains(local.env_keys, split(":", ref)[0]) ? (
      split(":", ref)[1] == "*" ?
      [for d in local.domain_keys : "${split(":", ref)[0]}:${d}:${split(":", ref)[2]}" if contains(local.domain_roles[d], split(":", ref)[2])] :
      ["${split(":", ref)[0]}:${split(":", ref)[1]}:${split(":", ref)[2]}"]
    ) : [ref]
  ) }

  unresolved_refs = [for ref, ts in local.ref_targets : ref if length(ts) == 0 || anytrue([for t in ts : !contains(keys(local.groups), t)])]

  # ---------------------------------------------------------------------------
  # Group nesting: child is a MEMBER of parent. An edge is owned by the scope of
  # its PARENT (the group that grants the access), except an edge into a shared
  # group, which is owned by the child's scope (shared must not depend on environments).
  # Infrastructure edges (persona -> role) are created with the groups.
  # Access edges (product consumers, SAR members) are approvals; stack 25 owns them.
  # ---------------------------------------------------------------------------
  persona_nesting = flatten([for pk, p in local.persona_defs : [
    for ref in p.access : [for t in local.ref_targets[ref] : {
      child = pk, parent = t, why = "persona", env = p.env
      # An edge into a SHARED group is owned by the child's scope, so `shared` never depends on an environment.
      scope = try(local.groups[t].scope == "shared" ? local.persona_groups[pk].scope : local.groups[t].scope, "unresolved")
      sid   = try(local.groups[t].scope == "shared" ? local.persona_groups[pk].sid : local.groups[t].sid, "unresolved")
    }]
  ]])

  # Product consumers: a domain consumer nests all its roles (same env); a consumer
  # domain nests its consumer groups (prod environment only).
  product_nesting = flatten([for e in local.env_keys : [
    for pk, cs in try(local.ent[e].product_access.products, {}) : [for c in cs : (
      contains(local.domain_keys, c) ? [
        for r in local.domain_roles[c] : { child = "${e}:${c}:${r}", parent = "product:${e}:${pk}", why = "product consumer", env = e, scope = "access", sid = "${e}/access" }
        ] : (contains(local.consumer_keys, c) && e == local.prod_env) ? [
        for r in local.consumers[c].roles : { child = "consumer:${c}:${r}", parent = "product:${e}:${pk}", why = "product consumer", env = e, scope = "access", sid = "${e}/access" }
      ] : []
    )]
  ]])

  sar_nesting = flatten([for e in local.env_keys : [
    for sk, refs in try(local.ent[e].sars.members, {}) : [for ref in refs : [for t in local.ref_targets[ref] : {
      child = t, parent = "sar:${e}:${sk}", why = "sar", env = e, scope = "access", sid = "${e}/access"
    }]]
  ]])

  infra_nesting  = { for n in local.persona_nesting : "${n.child}>${n.parent}" => n }
  access_nesting = { for n in concat(local.product_nesting, local.sar_nesting) : "${n.child}>${n.parent}" => n }

  # People added to groups by Terraform (stack 25-access). Consumer groups are never in this list.
  persona_assignments = flatten([for e in local.env_keys : [
    for upn, ps in try(local.ent[e].personas.users, {}) : [for p in ps : {
      env = e, upn = upn, group = "persona:${e}:${replace(p, "/", ":")}"
    }]
  ]])
  admin_assignments = flatten([for e in local.env_keys : [
    for d, upns in try(local.ent[e].admins.domains, {}) : [for u in upns : { env = e, upn = u, group = "${e}:${d}:dbadmin" }]
  ]])
  sandbox_assignments = flatten([for e in local.env_keys : [
    for u in try(local.ent[e].sandboxes.users, []) : { env = e, upn = u.upn, group = "platform:sandbox-users" }
  ]])
  experiment_assignments = flatten([for e in local.env_keys : [
    for x in try(local.ent[e].experiments.experiments, []) : [for m in x.members : { env = e, upn = m, group = "platform:${local.prod_env}-experimenters" }]
  ]])

  access_user_memberships = { for m in concat(
    local.persona_assignments, local.admin_assignments, local.sandbox_assignments, local.experiment_assignments,
    ) : "${m.env}|${m.upn}>${m.group}" => merge(m, { scope = "access", sid = "${m.env}/access" })
  }

  # Training-only test users (users are shared; their memberships are access).
  test_users = try(local.testusers.enabled, false) ? local.testusers.users : {}
  access_test_user_memberships = { for m in flatten([
    for uk, u in local.test_users : [for ref in u.member_of : [for t in local.ref_targets[ref] : {
      user = uk, group = t, env = try(local.groups[t].env, ""), scope = "access", sid = "${try(local.groups[t].env, "")}/access"
    }]]
  ]) : "${m.user}>${m.group}" => m }

  # ---------------------------------------------------------------------------
  # Service principals. Deployers and the vault loader are generated.
  # ---------------------------------------------------------------------------
  gh_org = local.platform.github.org

  extra_sp_env = { for k, s in local.spcfg.service_principals : k => length(keys(s.workspaces)) == 1 ? keys(s.workspaces)[0] : "" }

  service_principals = merge(
    { for p in setproduct(local.env_keys, local.domain_keys) : "deploy:${p[0]}:${p[1]}" => {
      display_name    = "sp-${local.prefix}-${p[0]}-${local.hy[p[1]]}-deploy"
      description     = "Deploys and runs the ${p[1]} domain in ${p[0]}; the only writer of its prod data"
      member_of       = ["${p[0]}:${p[1]}:producer", "writer:${p[0]}:${p[1]}"]
      workspaces      = { (p[0]) = "USER" }
      github_subjects = ["repo:${local.gh_org}/${local.domains[p[1]].repo}:environment:${p[0]}"]
      env             = p[0], scope = "domain:${p[1]}", sid = "${p[0]}/domain:${p[1]}"
    } },
    { for e in local.env_keys : "loader:${e}" => {
      display_name    = "sp-${local.prefix}-${e}-vault-loader"
      description     = "Loads landing, staging and the raw vault in ${e}"
      member_of       = ["vault:${e}:writer"]
      workspaces      = { (e) = "USER" }
      github_subjects = ["repo:${local.gh_org}/${local.vault.repo}:environment:${e}"]
      env             = e, scope = "env", sid = "${e}/env"
    } },
    { for k, s in local.spcfg.service_principals : "extra:${k}" => {
      display_name    = "sp-${local.prefix}-${k}"
      description     = s.description
      member_of       = distinct(flatten([for ref in s.member_of : local.ref_targets[ref]]))
      workspaces      = s.workspaces
      github_subjects = [for g in try(s.github_subjects, []) : "repo:${local.gh_org}/${g.repo}:environment:${g.environment}"]
      env             = local.extra_sp_env[k]
      scope           = local.extra_sp_env[k] == "" ? "shared" : "env"
      sid             = local.extra_sp_env[k] == "" ? "shared" : "${local.extra_sp_env[k]}/env"
    } },
  )

  # An SP -> group edge is owned by the scope of the group it joins (the SP's own scope when that group is shared).
  sp_memberships = { for m in flatten([
    for sk, s in local.service_principals : [for g in s.member_of : {
      sp    = sk, group = g, env = try(local.groups[g].env, "")
      scope = try(local.groups[g].scope == "shared" ? s.scope : local.groups[g].scope, "unresolved")
      sid   = try(local.groups[g].scope == "shared" ? s.sid : local.groups[g].sid, "unresolved")
    }]
  ]) : "${m.sp}>${m.group}" => m }

  # ---------------------------------------------------------------------------
  # Workspace assignments. Persona, product, SAR and writer groups are not
  # assigned: their members get workspace access through their own groups.
  # A shared group or principal is assigned to each workspace by that
  # environment's own run, so `shared` never depends on an environment.
  # ---------------------------------------------------------------------------
  group_workspace_assignments = merge(
    { for k, g in local.domain_groups : "${k}|${g.env}" => { group = k, env = g.env, permission = "USER", scope = g.scope, sid = g.sid } },
    { for k, g in local.vault_groups : "${k}|${g.env}" => { group = k, env = g.env, permission = "USER", scope = "env", sid = "${g.env}/env" } },
    { for k, g in local.consumer_groups : "${k}|${local.prod_env}" => { group = k, env = local.prod_env, permission = "USER", scope = "env", sid = "${local.prod_env}/env" } },
    merge([for k, g in local.pcfg.platform_groups : {
      for env, perm in g.workspaces : "platform:${k}|${env}" => { group = "platform:${k}", env = env, permission = perm, scope = "env", sid = "${env}/env" }
    }]...),
    { for e in local.env_keys : "platform:${e}-workspace-admins|${e}" => { group = "platform:${e}-workspace-admins", env = e, permission = "ADMIN", scope = "env", sid = "${e}/env" } },
  )

  sp_workspace_assignments = merge([for k, s in local.service_principals : {
    for env, perm in s.workspaces : "${k}|${env}" => {
      sp    = k, env = env, permission = perm
      scope = s.scope == "shared" ? "env" : s.scope, sid = s.scope == "shared" ? "${env}/env" : s.sid
    }
  }]...)

  # ---------------------------------------------------------------------------
  # Catalogs. container = storage container (hyphens only).
  # readonly_envs = other environments whose workspace gets a read-only binding.
  # ---------------------------------------------------------------------------
  catalogs = merge(
    { for e in local.env_keys : "vault:${e}" => {
      name    = "${e}_vault", env = e, kind = "vault", owner = "vault", container = "vault", readonly_envs = []
      comment = local.vault.description
      scope   = "env", sid = "${e}/env"
    } },
    { for p in setproduct(local.env_keys, local.domain_keys) : "domain:${p[0]}:${p[1]}" => {
      name    = "${p[0]}_${p[1]}", env = p[0], kind = "domain", owner = p[1], container = local.hy[p[1]], readonly_envs = []
      comment = local.domains[p[1]].description
      scope   = "domain:${p[1]}", sid = "${p[0]}/domain:${p[1]}"
    } },
    { for c in local.consumer_keys : "consumer:${local.prod_env}:${c}" => {
      name    = "${local.prod_env}_${c}", env = local.prod_env, kind = "consumer", owner = c, container = local.hy[c], readonly_envs = []
      comment = "Prep catalog of the ${c} consumer domain"
      scope   = "env", sid = "${local.prod_env}/env"
    } if try(local.consumers[c].prep_catalog, false) && length(local.prod_envs) == 1 },
    { for d in local.domain_keys : "anon:${local.prod_env}:${d}" => {
      name    = "${local.prod_env}_${d}_anon", env = local.prod_env, kind = "anon", owner = d, container = "${local.hy[d]}-anon", readonly_envs = local.nonprod_envs
      comment = "Irreversibly anonymized ${local.prod_env} data of the ${d} domain, readable from nonprod environments"
      scope   = "domain:${d}", sid = "${local.prod_env}/domain:${d}"
    } if try(local.domains[d].anon, false) && local.has_anon_path },
    { for e in local.env_keys : "platform:${e}" => {
      name    = "${e}_platform", env = e, kind = "platform", owner = "platform", container = "platform", readonly_envs = []
      comment = "Masking functions, audit, monitoring and observability views"
      scope   = "env", sid = "${e}/env"
    } },
    { for e in local.env_keys : "sandbox:${e}" => {
      name    = "${e}_sandbox", env = e, kind = "sandbox", owner = "sandbox", container = "sandbox", readonly_envs = []
      comment = local.env_tier[e] == "prod" ? "Approved experiments exp_<name>" : "Personal sandboxes u_<user>; nonprod data only"
      scope   = "env", sid = "${e}/env"
    } },
  )

  storage_containers = { for e in local.env_keys : e => distinct([for k, c in local.catalogs : c.container if c.env == e]) }

  bundle = local.matrix.bundles
  pg_env = { for e in local.env_keys : e => {
    sandbox     = lookup(local.gname, local.env_tier[e] == "prod" ? "platform:${local.prod_env}-experimenters" : "platform:sandbox-users", "")
    gov         = local.gname["platform:mesh-governance"]
    mon         = local.gname["platform:platform-monitoring"]
    wsadmin     = local.gname["platform:${e}-workspace-admins"]
    vault_write = local.gname["vault:${e}:writer"]
    vault_eng   = local.gname["vault:${e}:engineer"]
  } }

  # products of each domain
  domain_products = { for d in local.domain_keys : d => [for p, cfg in local.products : p if cfg.domain == d] }

  # ---------------------------------------------------------------------------
  # Catalog-level grants: catalog key -> [{principal, privileges}]
  # ---------------------------------------------------------------------------
  governance_grant = [{ principal = local.gname["platform:mesh-governance"], privileges = local.matrix.catalog.governance }]

  catalog_grants = { for ck, c in local.catalogs : ck => (
    c.kind == "domain" ? concat(
      [for r in local.domain_local_roles[c.owner] : { principal = local.gname["${c.env}:${c.owner}:${r}"], privileges = local.matrix.catalog.local_roles }],
      [{ principal = local.gname["${c.env}:${c.owner}:dbadmin"], privileges = local.matrix.catalog.dbadmin }],
      [for p in local.domain_products[c.owner] : { principal = local.gname["product:${c.env}:${p}"], privileges = local.matrix.catalog.product_group }],
      local.governance_grant,
      ) : c.kind == "vault" ? concat(
      [{ principal = local.pg_env[c.env].vault_write, privileges = local.matrix.vault.catalog.loader }],
      [{ principal = local.pg_env[c.env].vault_eng, privileges = local.matrix.vault.catalog.engineer }],
      [for d in local.domain_keys : { principal = local.gname["${c.env}:${d}:producer"], privileges = local.matrix.vault.catalog.readers }],
      [for d in local.domain_keys : { principal = local.gname["${c.env}:${d}:ai"], privileges = local.matrix.vault.catalog.readers }],
      local.governance_grant,
      ) : c.kind == "consumer" ? concat(
      [for r in local.consumers[c.owner].roles : { principal = local.gname["consumer:${c.owner}:${r}"], privileges = ["USE_CATALOG", "BROWSE"] }],
      local.governance_grant,
      ) : c.kind == "anon" ? concat(
      [{ principal = local.gname["writer:${c.env}:${c.owner}"], privileges = ["USE_CATALOG"] }],
      flatten([for e in local.nonprod_envs : [for r in local.domain_local_roles[c.owner] : { principal = local.gname["${e}:${c.owner}:${r}"], privileges = ["USE_CATALOG", "BROWSE"] }]]),
      local.governance_grant,
      ) : c.kind == "platform" ? [
      { principal = "account users", privileges = ["USE_CATALOG"] },
      { principal = local.pg_env[c.env].gov, privileges = ["ALL_PRIVILEGES", "MANAGE"] },
      { principal = local.pg_env[c.env].mon, privileges = ["USE_CATALOG", "BROWSE"] },
      ] : [
      { principal = local.pg_env[c.env].sandbox, privileges = ["USE_CATALOG", "BROWSE"] },
      { principal = local.pg_env[c.env].gov, privileges = ["USE_CATALOG", "BROWSE"] },
    ]
  ) }

  # ---------------------------------------------------------------------------
  # Schemas: "<catalog key>/<schema>" -> definition with grants and tags.
  # A bundle may be a plain value or {nonprod: .., prod: ..}; try() picks the tier.
  # ---------------------------------------------------------------------------
  domain_private_schemas = { for t in flatten([
    for e in local.env_keys : [for d in local.domain_keys : [for sn in keys(local.domain_schema_defs[d]) : { e = e, d = d, s = sn }]]
    ]) : "domain:${t.e}:${t.d}/${t.s}" => {
    catalog_key = "domain:${t.e}:${t.d}", catalog = "${t.e}_${t.d}", env = t.e, name = t.s
    comment     = local.domain_schema_defs[t.d][t.s].comment
    volumes     = try(local.domain_schema_defs[t.d][t.s].volumes, [])
    tags        = { piq_layer = local.domain_schema_defs[t.d][t.s].layer }
    scope       = "domain:${t.d}", sid = "${t.e}/domain:${t.d}"
    grants = concat(
      [for role, b in merge(try(local.matrix.domain[t.s], {}), try(local.dacc[t.d].schemas[t.s], {})) :
      { principal = local.gname["${t.e}:${t.d}:${role}"], privileges = local.bundle[try(b[local.env_tier[t.e]], b)] }],
      t.s == "event_log" ? [for p in local.domain_products[t.d] : { principal = local.gname["product:${t.e}:${p}"], privileges = local.bundle["R"] }] : [],
    )
  } }

  product_schemas = { for pr in setproduct(local.env_keys, local.product_keys) :
    "domain:${pr[0]}:${local.products[pr[1]].domain}/product_${pr[1]}" => {
      catalog_key = "domain:${pr[0]}:${local.products[pr[1]].domain}", catalog = "${pr[0]}_${local.products[pr[1]].domain}", env = pr[0]
      name        = "product_${pr[1]}"
      comment     = "Product ${pr[1]}: ${local.products[pr[1]].description}. Contract: ${local.products[pr[1]].contract}"
      volumes     = []
      scope       = "domain:${local.products[pr[1]].domain}", sid = "${pr[0]}/domain:${local.products[pr[1]].domain}"
      tags = {
        piq_layer          = "PRODUCT"
        piq_product        = pr[1]
        piq_product_type   = local.products[pr[1]].type
        piq_product_status = local.products[pr[1]].status
      }
      grants = [for who, b in merge(local.matrix.product, try(local.dacc[local.products[pr[1]].domain].product, {})) : {
        principal  = who == "product_group" ? local.gname["product:${pr[0]}:${pr[1]}"] : local.gname["${pr[0]}:${local.products[pr[1]].domain}:${who}"]
        privileges = local.bundle[try(b[local.env_tier[pr[0]]], b)]
      }]
    }
  }

  vault_schema_names = concat(
    [for s in keys(local.vault.schemas) : { name = s, kind = s }],
    [for src in local.vault.sources : { name = "stage_${src}", kind = "stage" }],
  )

  vault_schemas = { for t in setproduct(local.env_keys, local.vault_schema_names) :
    "vault:${t[0]}/${t[1].name}" => {
      catalog_key = "vault:${t[0]}", catalog = "${t[0]}_vault", env = t[0], name = t[1].name
      comment     = t[1].kind == "stage" ? "Staged ${trimprefix(t[1].name, "stage_")} data with hash keys and load metadata" : local.vault.schemas[t[1].kind].comment
      volumes     = t[1].kind == "stage" ? [] : try(local.vault.schemas[t[1].kind].volumes, [])
      tags        = { piq_layer = t[1].kind == "stage" ? "STAGE" : local.vault.schemas[t[1].kind].layer }
      scope       = "env", sid = "${t[0]}/env"
      grants = flatten([for who, b in local.matrix.vault.schemas[t[1].kind] : (
        who == "loader" ? [{ principal = local.pg_env[t[0]].vault_write, privileges = local.bundle[b] }] :
        who == "engineer" ? [{ principal = local.pg_env[t[0]].vault_eng, privileges = local.bundle[try(local.matrix.vault.overrides[local.env_tier[t[0]]].engineer, b)] }] :
        who == "domain_producer" ? [for d in local.domain_keys : { principal = local.gname["${t[0]}:${d}:producer"], privileges = local.bundle[b] }] :
        [for d in local.domain_keys : { principal = local.gname["${t[0]}:${d}:ai"], privileges = local.bundle[b] }]
      )])
    }
  }

  consumer_schemas = merge([for ck, c in local.catalogs : {
    for s in try(local.consumers[c.owner].prep_schemas, []) : "${ck}/${s}" => {
      catalog_key = ck, catalog = c.name, env = c.env, name = s
      comment     = "${s} for the ${c.owner} consumer domain"
      volumes     = []
      tags        = { piq_layer = "PREP" }
      scope       = "env", sid = c.sid
      grants      = [for r in local.consumers[c.owner].roles : { principal = local.gname["consumer:${c.owner}:${r}"], privileges = local.bundle[local.matrix.consumer_prep] }]
    }
  } if c.kind == "consumer"]...)

  anon_schemas = merge([for ck, c in local.catalogs : {
    for s in local.dcfg.anon_schemas : "${ck}/${s}" => {
      catalog_key = ck, catalog = c.name, env = c.env, name = s
      comment     = "Anonymized ${c.owner} data; never contains reversible personal data"
      volumes     = []
      tags        = { piq_layer = "ANON" }
      scope       = c.scope, sid = c.sid
      grants = concat(
        [{ principal = local.gname["writer:${c.env}:${c.owner}"], privileges = local.bundle[local.matrix.anon.writer] }],
        flatten([for e in local.nonprod_envs : [for r in local.domain_local_roles[c.owner] : { principal = local.gname["${e}:${c.owner}:${r}"], privileges = local.bundle[local.matrix.anon.nonprod_readers] }]]),
      )
    }
  } if c.kind == "anon"]...)

  platform_schemas = { for t in setproduct(local.env_keys, ["governance", "audit", "monitoring", "observability"]) :
    "platform:${t[0]}/${t[1]}" => {
      catalog_key = "platform:${t[0]}", catalog = "${t[0]}_platform", env = t[0], name = t[1]
      comment     = "Platform ${t[1]}"
      volumes     = []
      tags        = { piq_layer = "PLATFORM" }
      # Holds functions and views created by SQL outside Terraform (stacks 60 and 70): safe to drop with the schema.
      force_destroy = true
      scope         = "env", sid = "${t[0]}/env"
      grants = t[1] == "governance" ? [
        { principal = "account users", privileges = ["USE_SCHEMA", "EXECUTE"] },
        ] : [
        { principal = local.pg_env[t[0]].mon, privileges = ["USE_SCHEMA", "SELECT"] },
        { principal = local.pg_env[t[0]].gov, privileges = ["USE_SCHEMA", "SELECT"] },
      ]
    }
  }

  sandbox_schemas = merge(
    merge([for e in local.env_keys : {
      for u in try(local.ent[e].sandboxes.users, []) :
      "sandbox:${e}/u_${replace(lower(split("@", u.upn)[0]), "/[^a-z0-9]/", "_")}" => {
        catalog_key = "sandbox:${e}", catalog = "${e}_sandbox", env = e
        name        = "u_${replace(lower(split("@", u.upn)[0]), "/[^a-z0-9]/", "_")}"
        comment     = "Personal sandbox for ${u.upn} (${try(u.requested_via, "n/a")})"
        volumes     = []
        tags        = { piq_layer = "SCRATCH" }
        scope       = "env", sid = "${e}/env"
        grants      = [{ principal = u.upn, privileges = ["ALL_PRIVILEGES"] }]
      }
    }]...),
    merge([for e in local.env_keys : {
      for x in try(local.ent[e].experiments.experiments, []) :
      "sandbox:${e}/exp_${lower(x.name)}" => {
        catalog_key = "sandbox:${e}", catalog = "${e}_sandbox", env = e, name = "exp_${lower(x.name)}"
        comment     = "${x.description} | approved by ${x.approved_by} | ${x.ticket} | expires ${try(x.expires, "n/a")}"
        volumes     = []
        tags        = { piq_layer = "SCRATCH" }
        scope       = "env", sid = "${e}/env"
        grants      = [for m in x.members : { principal = m, privileges = ["ALL_PRIVILEGES"] }]
      }
    }]...),
  )

  schemas = merge(
    local.domain_private_schemas, local.product_schemas, local.vault_schemas,
    local.consumer_schemas, local.anon_schemas, local.platform_schemas, local.sandbox_schemas,
  )

  volumes = { for item in flatten([
    for sk, s in local.schemas : [for v in s.volumes : {
      key = "${sk}/${v}", catalog_key = s.catalog_key, catalog = s.catalog, schema_key = sk, schema = s.name, name = v, env = s.env, scope = s.scope, sid = s.sid
    }]
  ]) : item.key => item }

  # Users granted privileges directly (sandboxes, experiments), per environment.
  granted_users_by_env = { for e in local.env_keys : e => distinct(concat(
    [for u in try(local.ent[e].sandboxes.users, []) : u.upn],
    flatten([for x in try(local.ent[e].experiments.experiments, []) : x.members]),
  )) }
  granted_users = distinct(flatten(values(local.granted_users_by_env)))

  # ---------------------------------------------------------------------------
  # Warehouses per environment (workspace objects: no environment in the name).
  # ---------------------------------------------------------------------------
  wh = local.wsobj.warehouses

  warehouses = { for e in local.env_keys : e => merge(
    { for d in local.domain_keys : "piq-${local.hy[d]}-transform" => {
      size       = local.wh.domain.size, max_clusters = local.wh.domain.max_clusters, auto_stop_mins = local.wh.domain.auto_stop_mins
      can_use    = [for r in distinct(concat(local.wh.domain.CAN_USE, try(local.dacc[d].warehouse.CAN_USE, []))) : local.gname["${e}:${d}:${r}"]]
      can_manage = concat([for r in distinct(concat(local.wh.domain.CAN_MANAGE, try(local.dacc[d].warehouse.CAN_MANAGE, []))) : local.gname["${e}:${d}:${r}"]], [local.pg_env[e].wsadmin])
      tags       = { piq_env = e, piq_domain = d, piq_workload = "transform" }
      scope      = "domain:${d}", sid = "${e}/domain:${d}"
    } },
    { "piq-vault-load" = {
      size       = local.wh.vault.size, max_clusters = local.wh.vault.max_clusters, auto_stop_mins = local.wh.vault.auto_stop_mins
      can_use    = [local.pg_env[e].vault_write, local.pg_env[e].vault_eng]
      can_manage = [local.pg_env[e].wsadmin]
      tags       = { piq_env = e, piq_domain = "vault", piq_workload = "load" }
      scope      = "env", sid = "${e}/env"
    } },
    { for c in local.consumer_keys : "piq-${local.hy[c]}-bi" => {
      size           = try(local.consumers[c].warehouse.size, local.wh.consumer.size)
      max_clusters   = try(local.consumers[c].warehouse.max_clusters, local.wh.consumer.max_clusters)
      auto_stop_mins = try(local.consumers[c].warehouse.auto_stop_mins, local.wh.consumer.auto_stop_mins)
      can_use        = [for r in local.consumers[c].roles : local.gname["consumer:${c}:${r}"]]
      can_manage     = [local.pg_env[e].wsadmin]
      tags           = { piq_env = e, piq_domain = c, piq_workload = "bi" }
      scope          = "env", sid = "${e}/env"
    } if e == local.prod_env },
    { "piq-shared" = {
      size       = local.wh.shared.size, max_clusters = local.wh.shared.max_clusters, auto_stop_mins = local.wh.shared.auto_stop_mins
      can_use    = [local.pg_env[e].sandbox, local.pg_env[e].gov, local.pg_env[e].mon]
      can_manage = [local.pg_env[e].wsadmin]
      tags       = { piq_env = e, piq_domain = "shared", piq_workload = "shared" }
      scope      = "env", sid = "${e}/env"
    } },
  ) }

  # env -> role -> group names across all domains that define the role
  # (for policies, endpoints)
  role_groups = { for e in local.env_keys : e => {
    for r in local.all_roles : r => [for d in local.domain_keys : local.gname["${e}:${d}:${r}"] if contains(local.domain_roles[d], r)]
  } }

  # ---------------------------------------------------------------------------
  # Serverless usage policies: one per env x owner; principals may use it.
  # ---------------------------------------------------------------------------
  usage_scopes = local.cost.usage_policies.enabled ? merge(
    { for p in setproduct(local.env_keys, local.domain_keys) : "${p[0]}:${p[1]}" => {
      env        = p[0], owner = p[1], kind = "domain", name = "${local.prefix}-${p[0]}-${local.hy[p[1]]}"
      principals = concat([for r in local.domain_roles[p[1]] : local.gname["${p[0]}:${p[1]}:${r}"]], [local.gname["writer:${p[0]}:${p[1]}"]])
      scope      = "domain:${p[1]}", sid = "${p[0]}/domain:${p[1]}"
    } },
    { for e in local.env_keys : "${e}:vault" => {
      env        = e, owner = "vault", kind = "vault", name = "${local.prefix}-${e}-vault"
      principals = [local.pg_env[e].vault_write, local.pg_env[e].vault_eng]
      scope      = "env", sid = "${e}/env"
    } },
    { for c in local.consumer_keys : "${local.prod_env}:${c}" => {
      env        = local.prod_env, owner = c, kind = "consumer", name = "${local.prefix}-${local.prod_env}-${local.hy[c]}"
      principals = [for r in local.consumers[c].roles : local.gname["consumer:${c}:${r}"]]
      scope      = "env", sid = "${local.prod_env}/env"
    } if length(local.prod_envs) == 1 },
    { for e in local.env_keys : "${e}:platform" => {
      env        = e, owner = "platform", kind = "platform", name = "${local.prefix}-${e}-platform"
      principals = [local.pg_env[e].gov, local.pg_env[e].mon]
      scope      = "env", sid = "${e}/env"
    } },
    { for e in local.env_keys : "${e}:sandbox" => {
      env        = e, owner = "sandbox", kind = "sandbox", name = "${local.prefix}-${e}-sandbox"
      principals = [local.pg_env[e].sandbox]
      scope      = "env", sid = "${e}/env"
    } },
  ) : {}

  # ---------------------------------------------------------------------------
  # Governed tags with generated values, and who may assign them. Tags exist once
  # for the whole account, so they are SHARED.
  # ---------------------------------------------------------------------------
  generated_tag_values = {
    piq_env            = local.env_keys
    piq_domain         = sort(concat(local.domain_keys, local.consumer_keys, ["vault", "platform", "sandbox", "shared"]))
    piq_product        = local.product_keys
    piq_steward_domain = local.domain_keys
    piq_source_system  = sort(local.vault.sources)
  }

  governed_tags = { for tk, t in local.tagcfg.tags : tk => {
    description = t.description
    values      = try(tolist(t.values), local.generated_tag_values[tk])
    assigners = distinct(flatten([for a in t.assigners : (
      startswith(a, "role:") ? [for k, g in local.domain_groups : g.name if g.role == trimprefix(a, "role:")] :
      a == "vault:writer" ? [for e in local.env_keys : local.pg_env[e].vault_write] :
      [local.gname["platform:${a}"]]
    )]))
    scope = "shared", sid = "shared"
  } }

  # ---------------------------------------------------------------------------
  # ABAC column masks: one policy per (domain | vault | consumer catalog) x mask.
  # Exceptions: SAR groups that unlock the mask, and the catalog's data writers.
  # ---------------------------------------------------------------------------
  mask_sars = { for mk, m in local.masks : mk => [for sk, s in local.sars : sk if contains(s.unlocks, mk)] }

  abac_policies = { for t in setproduct([for k, c in local.catalogs : k if contains(["domain", "vault", "consumer"], c.kind)], keys(local.masks)) :
    "${t[0]}|${t[1]}" => {
      catalog_key = t[0]
      catalog     = local.catalogs[t[0]].name
      env         = local.catalogs[t[0]].env
      scope       = local.catalogs[t[0]].scope
      sid         = local.catalogs[t[0]].sid
      mask        = t[1]
      name        = "mask_${t[1]}"
      function    = "${local.catalogs[t[0]].env}_platform.governance.${local.masks[t[1]].function}"
      condition   = "has_tag_value('${local.masks[t[1]].tag}', '${local.masks[t[1]].value}')"
      except = concat(
        [for sk in local.mask_sars[t[1]] : local.gname["sar:${local.catalogs[t[0]].env}:${sk}"]],
        local.catalogs[t[0]].kind == "domain" ? [local.gname["writer:${local.catalogs[t[0]].env}:${local.catalogs[t[0]].owner}"]] : [],
        local.catalogs[t[0]].kind == "vault" ? [local.pg_env[local.catalogs[t[0]].env].vault_write] : [],
      )
    }
  }

  # ---------------------------------------------------------------------------
  # Scope filter. `want` is the sid this run applies; null = everything.
  # ---------------------------------------------------------------------------
  scope_s = var.scope == null ? "unset" : var.scope
  want    = var.scope == null ? null : (var.scope == "shared" ? "shared" : "${coalesce(var.environment, "?")}/${var.scope}")

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------
  bundle_rank = { for i, b in local.matrix.bundle_order : b => i }

  # Humans may not join sp-only groups in the prod environment (standard roles plus
  # any extra role declared service_principal_only).
  sp_only_parents = [for n in values(local.infra_nesting) : "${n.child} -> ${n.parent}"
    if n.why == "persona" && length(split(":", n.parent)) == 3 && split(":", n.parent)[0] == local.prod_env
    && contains(try(local.sp_only_roles[split(":", n.parent)[1]], []), split(":", n.parent)[2])
  ]
  test_user_sp_only = [for m in values(local.access_test_user_memberships) : "${m.user} -> ${m.group}"
    if length(split(":", m.group)) == 3 && split(":", m.group)[0] == local.prod_env
    && contains(try(local.sp_only_roles[split(":", m.group)[1]], []), split(":", m.group)[2])
  ]

  # A persona may only reach its own environment's groups and workspaces; a domain
  # persona only its own domain's roles.
  persona_env_leaks = flatten([for pk, p in local.persona_defs : [for ref in p.access : "${pk}: ${ref}" if(
    (contains(local.env_keys, split(":", ref)[0]) && split(":", ref)[0] != p.env) ||
    (split(":", ref)[0] == "vault" && try(split(":", ref)[1], "") != p.env) ||
    (length(split(":", ref)) == 1 && !contains(try(local.pg_workspaces[ref], []), p.env)) ||
    (p.domain != "" && contains(local.env_keys, split(":", ref)[0]) && try(split(":", ref)[1], "") != p.domain) ||
    (p.domain != "" && split(":", ref)[0] == "vault")
  )]])

  bad_consumers = flatten([for e in local.env_keys : [
    for pk, cs in try(local.ent[e].product_access.products, {}) : [for c in cs :
      "${e}/${pk}: ${c}" if !contains(keys(local.products), pk) || (contains(local.domain_keys, c) && c == try(local.products[pk].domain, "")) ||
      !(contains(local.domain_keys, c) || (contains(local.consumer_keys, c) && e == local.prod_env))
    ]
  ]])
  bad_products    = [for p, cfg in local.products : p if !contains(local.domain_keys, cfg.domain)]
  bad_sar_masks   = flatten([for sk, s in local.sars : [for m in s.unlocks : "${sk}: ${m}" if !contains(keys(local.masks), m)]])
  bad_sar_members = flatten([for e in local.env_keys : [for sk, refs in try(local.ent[e].sars.members, {}) : "${e}: ${sk}" if !contains(keys(local.sars), sk)]])
  bad_mask_tags   = [for mk, m in local.masks : mk if !contains(try(local.governed_tags[m.tag].values, []), m.value)]
  reserved_hits   = setintersection(concat(local.domain_keys, local.consumer_keys), local.dcfg.reserved)
  key_overlap     = setintersection(local.domain_keys, local.consumer_keys)

  # Entitlement files that do not belong in their environment.
  bad_entitlement_env = concat(
    [for e in local.env_keys : "${e}: sandboxes belong in a nonprod environment" if length(try(local.ent[e].sandboxes.users, [])) > 0 && local.env_tier[e] != "nonprod"],
    [for e in local.env_keys : "${e}: experiments belong in the prod environment" if length(try(local.ent[e].experiments.experiments, [])) > 0 && local.env_tier[e] != "prod"],
  )
  unresolved_assignments = [for m in values(local.access_user_memberships) : "${m.env}: ${m.upn} -> ${m.group}" if !contains(keys(local.groups), m.group)]

  # Domain shape and access: names, references and the access ceiling.
  domain_collisions = flatten([for d in local.domain_keys : concat(
    [for r in keys(local.extra_roles[d]) : "${d}: role ${r} collides with a standard or reserved role" if contains(concat(local.matrix.roles, ["writer"]), r)],
    [for sn in keys(try(local.dshape[d].schemas.add, {})) : "${d}: schema ${sn} collides with a standard schema or uses the product_ prefix" if contains(keys(local.dcfg.schemas), sn) || startswith(sn, "product_")],
    [for sn in try(local.dshape[d].schemas.remove, []) : "${d}: schema ${sn} cannot be removed" if sn == "admin" || !contains(keys(local.dcfg.schemas), sn)],
    [for k, p in try(local.dshape[d].personas, {}) : "${d}: persona ${k} collides with a global persona" if contains(keys(local.pcfg.personas), k)],
  )])
  bad_domain_access = flatten([for d in local.domain_keys : concat(
    [for sn, row in try(local.dacc[d].schemas, {}) : "${d}: access for unknown schema ${sn}" if !contains(keys(local.domain_schema_defs[d]), sn) || sn == "admin"],
    flatten([for sn, row in try(local.dacc[d].schemas, {}) : [for r, b in row :
      "${d}.${sn}: unknown role ${r}" if !contains(local.domain_roles[d], r)
    ]]),
    flatten([for sn, row in try(local.dacc[d].schemas, {}) : [for r, b in row : [for t in ["nonprod", "prod"] :
      "${d}.${sn}.${r}: bundle above the ceiling (${local.matrix.override_ceiling})" if try(local.bundle_rank[try(b[t], b)], 99) > local.bundle_rank[local.matrix.override_ceiling]
    ]]]),
    [for k, p in try(local.dacc[d].personas, {}) : "${d}: access for undeclared persona ${k}" if !contains(keys(try(local.dshape[d].personas, {})), k)],
  )])
}

# -----------------------------------------------------------------------------
# Outputs. Each is filtered to the requested scope; unset = complete.
# -----------------------------------------------------------------------------
output "prefix" { value = local.prefix }
output "platform" { value = local.platform }
output "environments" { value = local.environments }
output "env_keys" { value = local.env_keys }
output "env_tier" { value = local.env_tier }
output "prod_env" { value = local.prod_env }
output "nonprod_envs" { value = local.nonprod_envs }
output "domains" { value = local.domains }
output "domain_keys" { value = local.domain_keys }
output "domain_roles" { value = local.domain_roles }
output "consumers" { value = local.consumers }
output "consumer_keys" { value = local.consumer_keys }
output "products" { value = local.products }
output "vault" { value = local.vault }
output "roles" { value = local.matrix.roles }
output "all_group_names" {
  description = "Every group key -> display name, unfiltered. For referencing groups owned by another scope."
  value       = local.gname
}
output "groups" { value = { for k, v in local.groups : k => v if local.want == null || v.sid == local.want } }
output "nesting" { value = { for k, v in local.infra_nesting : k => v if local.want == null || v.sid == local.want } }
output "access_nesting" { value = { for k, v in local.access_nesting : k => v if local.want == null || v.sid == local.want } }
output "access_user_memberships" { value = { for k, v in local.access_user_memberships : k => v if local.want == null || v.sid == local.want } }
output "access_test_user_memberships" { value = { for k, v in local.access_test_user_memberships : k => v if local.want == null || v.sid == local.want } }
output "test_users" { value = local.want == null || local.want == "shared" ? local.test_users : {} }
output "all_service_principal_names" {
  description = "Every service principal key -> display name, unfiltered. For referencing SPs owned by another scope."
  value       = { for k, s in local.service_principals : k => s.display_name }
}
output "service_principals" { value = { for k, v in local.service_principals : k => v if local.want == null || v.sid == local.want } }
output "sp_memberships" { value = { for k, v in local.sp_memberships : k => v if local.want == null || v.sid == local.want } }
output "group_workspace_assignments" { value = { for k, v in local.group_workspace_assignments : k => v if local.want == null || v.sid == local.want } }
output "sp_workspace_assignments" { value = { for k, v in local.sp_workspace_assignments : k => v if local.want == null || v.sid == local.want } }
output "catalogs" { value = { for k, v in local.catalogs : k => v if local.want == null || v.sid == local.want } }
output "storage_containers" {
  description = "Per environment. Containers of every catalog in the environment, created by the env scope."
  value       = local.want == null ? local.storage_containers : { for e, cs in local.storage_containers : e => (local.want == "${e}/env" ? cs : []) }
}
output "catalog_grants" { value = { for k, v in local.catalog_grants : k => v if local.want == null || local.catalogs[k].sid == local.want } }
output "schemas" { value = { for k, v in local.schemas : k => v if local.want == null || v.sid == local.want } }
output "volumes" { value = { for k, v in local.volumes : k => v if local.want == null || v.sid == local.want } }
output "granted_users" {
  description = "Users granted privileges directly (sandboxes, experiments) in this run's environment"
  value       = local.want == null ? local.granted_users : (var.environment != null && local.want == "${coalesce(var.environment, "?")}/env" ? local.granted_users_by_env[var.environment] : [])
}
output "warehouses" { value = { for e, ws in local.warehouses : e => { for n, w in ws : n => w if local.want == null || w.sid == local.want } } }
output "role_groups" { value = local.role_groups }
output "platform_group_names" { value = { for k, g in local.platform_groups : trimprefix(k, "platform:") => g.name } }
output "usage_scopes" { value = { for k, v in local.usage_scopes : k => v if local.want == null || v.sid == local.want } }
output "governed_tags" { value = { for k, v in local.governed_tags : k => v if local.want == null || v.sid == local.want } }
output "masks" { value = local.masks }
output "abac_policies" { value = { for k, v in local.abac_policies : k => v if local.want == null || v.sid == local.want } }
output "workspace_objects" { value = local.wsobj }
output "cost" { value = local.cost }
output "sars" { value = local.sars }
output "matrix" { value = local.matrix }

output "user_memberships" {
  description = "Legacy name for access_user_memberships (stack 25 reads access_user_memberships)"
  value       = { for k, v in local.access_user_memberships : k => v if local.want == null || v.sid == local.want }
}
output "test_user_memberships" {
  description = "Legacy name for access_test_user_memberships"
  value       = { for k, v in local.access_test_user_memberships : k => v if local.want == null || v.sid == local.want }
}

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
    condition     = length(local.prod_envs) == 1 && length(local.prod_envs) + length(local.nonprod_envs) == length(local.env_keys)
    error_message = "Exactly one environment must have tier: prod and every other tier: nonprod (got prod=${join(",", local.prod_envs)}, nonprod=${join(",", local.nonprod_envs)})"
  }
  precondition {
    condition     = var.scope == null || contains(["shared", "env", "access"], local.scope_s) || startswith(local.scope_s, "domain:")
    error_message = "scope must be shared, env, access or domain:<name>"
  }
  precondition {
    condition     = var.scope == null || var.scope == "shared" || (var.environment != null && contains(local.env_keys, coalesce(var.environment, "?")))
    error_message = "environment must be one of ${join(", ", local.env_keys)} when scope is ${local.scope_s}"
  }
  precondition {
    condition     = var.scope == null || !startswith(local.scope_s, "domain:") || contains(local.domain_keys, trimprefix(local.scope_s, "domain:"))
    error_message = "scope names an unknown domain: ${local.scope_s}"
  }
  precondition {
    condition     = length(local.sp_only_parents) == 0 && length(local.test_user_sp_only) == 0
    error_message = "Humans may not join prod-tier groups of service-principal-only roles: ${join(", ", concat(local.sp_only_parents, local.test_user_sp_only))}"
  }
  precondition {
    condition     = length(local.persona_env_leaks) == 0
    error_message = "A persona may only reference its own environment's groups and workspaces, and a domain persona only its own domain's roles: ${join(", ", local.persona_env_leaks)}"
  }
  precondition {
    condition     = length(local.reserved_hits) == 0 && length(local.key_overlap) == 0
    error_message = "Domain or consumer keys are reserved or overlap: ${join(", ", concat(tolist(local.reserved_hits), tolist(local.key_overlap)))}"
  }
  precondition {
    condition     = length(local.product_name_list) == length(distinct(local.product_name_list))
    error_message = "Product names must be unique across config/products/*.yaml"
  }
  precondition {
    condition     = length(local.bad_products) == 0
    error_message = "Product files must be named after an existing domain: ${join(", ", local.bad_products)}"
  }
  precondition {
    condition     = length(local.bad_consumers) == 0
    error_message = "Product consumers must be another domain or a consumer domain (consumer domains only in the prod environment): ${join(", ", local.bad_consumers)}"
  }
  precondition {
    condition     = length(local.unresolved_refs) == 0
    error_message = "Group references that resolve to no group: ${join(", ", local.unresolved_refs)}"
  }
  precondition {
    condition     = length(local.unresolved_assignments) == 0
    error_message = "Persona assignments that resolve to no group: ${join(", ", local.unresolved_assignments)}"
  }
  precondition {
    condition     = length(local.bad_sar_masks) == 0 && length(local.bad_mask_tags) == 0 && length(local.bad_sar_members) == 0
    error_message = "SARs must unlock defined masks, masks must use governed tag values, and entitlements may only name defined SARs: ${join(", ", concat(local.bad_sar_masks, local.bad_mask_tags, local.bad_sar_members))}"
  }
  precondition {
    condition     = length(local.bad_entitlement_env) == 0
    error_message = "Entitlements in the wrong environment tier: ${join("; ", local.bad_entitlement_env)}"
  }
  precondition {
    condition     = length(local.domain_collisions) == 0
    error_message = "Domain shape errors: ${join("; ", local.domain_collisions)}"
  }
  precondition {
    condition     = length(local.bad_domain_access) == 0
    error_message = "Domain access errors: ${join("; ", local.bad_domain_access)}"
  }
}
