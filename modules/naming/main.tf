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
# =============================================================================

variable "config_dir" {
  description = "Path to the repo's config/ directory"
  type        = string
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
  sandbox   = yamldecode(file("${var.config_dir}/sandbox_users.yaml"))
  exps      = yamldecode(file("${var.config_dir}/experiments.yaml"))
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
      consumers   = try(p.consumers, [])
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
  roles         = local.matrix.roles
  local_roles   = [for r in local.roles : r if r != "dbadmin"]
  vault         = local.dcfg.vault
  sars          = local.sarcfg.sars
  masks         = local.tagcfg.masks
  has_anon_path = contains(local.env_keys, "dev") && contains(local.env_keys, "prd")

  hy = { for k in concat(local.domain_keys, local.consumer_keys, local.product_keys, keys(local.sars)) : k => replace(k, "_", "-") }

  # ---------------------------------------------------------------------------
  # Groups. Every group is an Entra security group, visible in Databricks
  # through automatic identity management. Every value has the same shape.
  #   kind: domain | writer | vault | product | consumer | sar | platform | persona
  #   lead: Entra owner for consumer groups (membership managed by the lead)
  # ---------------------------------------------------------------------------
  domain_groups = { for t in setproduct(local.env_keys, local.domain_keys, local.roles) :
    "${t[0]}:${t[1]}:${t[2]}" => {
      name        = "${local.prefix}-${t[0]}-${local.hy[t[1]]}-${t[2]}", kind = "domain", env = t[0], owner = t[1], role = t[2], lead = ""
      description = "${t[2]} role of the ${t[1]} domain in ${t[0]}"
    }
  }

  writer_groups = { for p in setproduct(local.env_keys, local.domain_keys) :
    "writer:${p[0]}:${p[1]}" => {
      name        = "${local.prefix}-${p[0]}-${local.hy[p[1]]}-writer", kind = "writer", env = p[0], owner = p[1], role = "writer", lead = ""
      description = "Data writers of the ${p[1]} domain in ${p[0]} (deploy service principal only); exempt from masks"
    }
  }

  vault_groups = { for p in setproduct(local.env_keys, ["engineer", "writer"]) :
    "vault:${p[0]}:${p[1]}" => {
      name        = "${local.prefix}-${p[0]}-vault-${p[1]}", kind = "vault", env = p[0], owner = "vault", role = p[1], lead = ""
      description = p[1] == "writer" ? "Vault loader in ${p[0]} (service principal only); sole writer to ${p[0]}_vault" : "Vault engineers in ${p[0]}"
    }
  }

  product_groups = { for p in setproduct(local.env_keys, local.product_keys) :
    "product:${p[0]}:${p[1]}" => {
      name        = "${local.prefix}-${p[0]}-product-${local.hy[p[1]]}", kind = "product", env = p[0], owner = local.products[p[1]].domain, role = p[1], lead = ""
      description = "Readers of the ${p[1]} product (${local.products[p[1]].domain}) in ${p[0]}"
    }
  }

  consumer_groups = { for item in flatten([
    for ck, c in local.consumers : [for r in c.roles : { ck = ck, r = r, lead = c.lead }]
    ]) : "consumer:${item.ck}:${item.r}" => {
    name        = "${local.prefix}-prd-${local.hy[item.ck]}-${item.r}", kind = "consumer", env = "prd", owner = item.ck, role = item.r, lead = item.lead
    description = "${item.r} role of the ${item.ck} consumer domain; membership managed by ${item.lead}"
  } }

  sar_groups = { for p in setproduct(local.env_keys, keys(local.sars)) :
    "sar:${p[0]}:${p[1]}" => {
      name        = "${local.prefix}-${p[0]}-sar-${local.hy[p[1]]}", kind = "sar", env = p[0], owner = "governance", role = p[1], lead = ""
      description = "Sensitive access role ${p[1]} in ${p[0]}: ${local.sars[p[1]].description}"
    }
  }

  platform_groups = { for k, g in local.pcfg.platform_groups :
    "platform:${k}" => {
      name        = "${local.prefix}-${k}", kind = "platform", env = "", owner = "platform", role = k, lead = ""
      description = g.description
    }
  }

  persona_groups = { for k, p in local.pcfg.personas :
    "persona:${k}" => {
      name        = "${local.prefix}-persona-${k}", kind = "persona", env = "", owner = "persona", role = k, lead = ""
      description = p.description
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
  #   "persona:<name>"           "<platform-key>"
  # ---------------------------------------------------------------------------
  all_refs = distinct(concat(
    flatten([for p in values(local.pcfg.personas) : p.member_of]),
    flatten([for s in values(local.spcfg.service_principals) : s.member_of]),
    flatten([for s in values(local.sars) : flatten(values(s.members))]),
    flatten([for u in values(try(local.testusers.users, {})) : u.member_of]),
  ))

  ref_targets = { for ref in local.all_refs : ref => (
    length(split(":", ref)) == 1 ? ["platform:${ref}"] :
    contains(local.env_keys, split(":", ref)[0]) ? [
      for d in(split(":", ref)[1] == "*" ? local.domain_keys : [split(":", ref)[1]]) :
      "${split(":", ref)[0]}:${d}:${split(":", ref)[2]}"
    ] : [ref]
  ) }

  unresolved_refs = [for ref, ts in local.ref_targets : ref if anytrue([for t in ts : !contains(keys(local.groups), t)])]

  # ---------------------------------------------------------------------------
  # Group nesting: child is a MEMBER of parent.
  # ---------------------------------------------------------------------------
  persona_nesting = flatten([for pk, p in local.pcfg.personas : [
    for ref in p.member_of : [for t in local.ref_targets[ref] : { child = "persona:${pk}", parent = t, why = "persona" }]
  ]])

  # Product consumers: a domain consumer nests all its local roles (same env);
  # a consumer domain nests its consumer groups (prd only).
  product_nesting = flatten([for pr in setproduct(local.env_keys, local.product_keys) : [
    for c in local.products[pr[1]].consumers : (
      contains(local.domain_keys, c) ? [
        for r in local.roles : { child = "${pr[0]}:${c}:${r}", parent = "product:${pr[0]}:${pr[1]}", why = "product consumer" }
        ] : contains(local.consumer_keys, c) && pr[0] == "prd" ? [
        for r in local.consumers[c].roles : { child = "consumer:${c}:${r}", parent = "product:${pr[0]}:${pr[1]}", why = "product consumer" }
      ] : []
    )
  ]])

  sar_nesting = flatten([for sk, s in local.sars : [
    for env, refs in s.members : [
      for ref in refs : [for t in local.ref_targets[ref] : { child = t, parent = "sar:${env}:${sk}", why = "sar" }]
    ]
  ]])

  nesting = { for n in concat(local.persona_nesting, local.product_nesting, local.sar_nesting) :
    "${n.child}>${n.parent}" => n
  }

  # Users added to groups by Terraform (consumer groups are never in this list).
  user_memberships = { for m in flatten([
    [for pk, p in local.pcfg.personas : [for u in try(p.members, []) : { upn = u, group = "persona:${pk}" }]],
    [for e in local.env_keys : [for d, cfg in local.domains : [for u in try(cfg.admins, []) : { upn = u, group = "${e}:${d}:dbadmin" }]]],
    [for u in try(local.sandbox.users, []) : { upn = u.upn, group = "platform:sandbox-users" }],
    [for e in try(local.exps.experiments, []) : [for u in e.members : { upn = u, group = "platform:prd-experimenters" }]],
  ]) : "${m.upn}>${m.group}" => m }

  # Training-only test users and their memberships (may include consumer groups).
  test_users = try(local.testusers.enabled, false) ? local.testusers.users : {}
  test_user_memberships = { for m in flatten([
    for uk, u in local.test_users : [for ref in u.member_of : [for t in local.ref_targets[ref] : { user = uk, group = t }]]
  ]) : "${m.user}>${m.group}" => m }

  # ---------------------------------------------------------------------------
  # Service principals. Deployers and the vault loader are generated.
  # ---------------------------------------------------------------------------
  gh_org = local.platform.github.org

  service_principals = merge(
    { for p in setproduct(local.env_keys, local.domain_keys) : "deploy:${p[0]}:${p[1]}" => {
      display_name    = "sp-${local.prefix}-${p[0]}-${local.hy[p[1]]}-deploy"
      description     = "Deploys and runs the ${p[1]} domain in ${p[0]}; the only writer of its prd data"
      member_of       = ["${p[0]}:${p[1]}:producer", "writer:${p[0]}:${p[1]}"]
      workspaces      = { (p[0]) = "USER" }
      github_subjects = ["repo:${local.gh_org}/${local.domains[p[1]].repo}:environment:${p[0]}"]
    } },
    { for e in local.env_keys : "loader:${e}" => {
      display_name    = "sp-${local.prefix}-${e}-vault-loader"
      description     = "Loads landing, staging and the raw vault in ${e}"
      member_of       = ["vault:${e}:writer"]
      workspaces      = { (e) = "USER" }
      github_subjects = ["repo:${local.gh_org}/${local.vault.repo}:environment:${e}"]
    } },
    { for k, s in local.spcfg.service_principals : "extra:${k}" => {
      display_name    = "sp-${local.prefix}-${k}"
      description     = s.description
      member_of       = distinct(flatten([for ref in s.member_of : local.ref_targets[ref]]))
      workspaces      = s.workspaces
      github_subjects = [for g in try(s.github_subjects, []) : "repo:${local.gh_org}/${g.repo}:environment:${g.environment}"]
    } },
  )

  sp_memberships = { for m in flatten([
    for sk, s in local.service_principals : [for g in s.member_of : { sp = sk, group = g }]
  ]) : "${m.sp}>${m.group}" => m }

  # ---------------------------------------------------------------------------
  # Workspace assignments. Persona, product, SAR and writer groups are not
  # assigned: their members get workspace access through their own groups.
  # ---------------------------------------------------------------------------
  group_workspace_assignments = merge(
    { for k, g in local.domain_groups : "${k}|${g.env}" => { group = k, env = g.env, permission = "USER" } },
    { for k, g in local.vault_groups : "${k}|${g.env}" => { group = k, env = g.env, permission = "USER" } },
    { for k, g in local.consumer_groups : "${k}|prd" => { group = k, env = "prd", permission = "USER" } },
    merge([for k, g in local.pcfg.platform_groups : {
      for env, perm in g.workspaces : "platform:${k}|${env}" => { group = "platform:${k}", env = env, permission = perm }
    }]...),
  )

  sp_workspace_assignments = merge([for k, s in local.service_principals : {
    for env, perm in s.workspaces : "${k}|${env}" => { sp = k, env = env, permission = perm }
  }]...)

  # ---------------------------------------------------------------------------
  # Catalogs. container = storage container (hyphens only).
  # readonly_envs = other environments whose workspace gets a read-only binding.
  # ---------------------------------------------------------------------------
  catalogs = merge(
    { for e in local.env_keys : "vault:${e}" => {
      name    = "${e}_vault", env = e, kind = "vault", owner = "vault", container = "vault", readonly_envs = []
      comment = local.vault.description
    } },
    { for p in setproduct(local.env_keys, local.domain_keys) : "domain:${p[0]}:${p[1]}" => {
      name    = "${p[0]}_${p[1]}", env = p[0], kind = "domain", owner = p[1], container = local.hy[p[1]], readonly_envs = []
      comment = local.domains[p[1]].description
    } },
    { for c in local.consumer_keys : "consumer:prd:${c}" => {
      name    = "prd_${c}", env = "prd", kind = "consumer", owner = c, container = local.hy[c], readonly_envs = []
      comment = "Prep catalog of the ${c} consumer domain"
    } if try(local.consumers[c].prep_catalog, false) && contains(local.env_keys, "prd") },
    { for d in local.domain_keys : "anon:prd:${d}" => {
      name    = "prd_${d}_anon", env = "prd", kind = "anon", owner = d, container = "${local.hy[d]}-anon", readonly_envs = ["dev"]
      comment = "Irreversibly anonymized prd data of the ${d} domain, readable from dev"
    } if try(local.domains[d].anon, false) && local.has_anon_path },
    { for e in local.env_keys : "platform:${e}" => {
      name    = "${e}_platform", env = e, kind = "platform", owner = "platform", container = "platform", readonly_envs = []
      comment = "Masking functions, audit, monitoring and observability views"
    } },
    { for e in local.env_keys : "sandbox:${e}" => {
      name    = "${e}_sandbox", env = e, kind = "sandbox", owner = "sandbox", container = "sandbox", readonly_envs = []
      comment = e == "dev" ? "Personal sandboxes u_<user>; dev data only" : "Approved experiments exp_<name>"
    } },
  )

  storage_containers = { for e in local.env_keys : e => distinct([for k, c in local.catalogs : c.container if c.env == e]) }

  bundle = local.matrix.bundles
  pg_env = { for e in local.env_keys : e => {
    sandbox     = local.gname[e == "dev" ? "platform:sandbox-users" : "platform:prd-experimenters"]
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
      [for r in local.local_roles : { principal = local.gname["${c.env}:${c.owner}:${r}"], privileges = local.matrix.catalog.local_roles }],
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
      [{ principal = local.gname["writer:prd:${c.owner}"], privileges = ["USE_CATALOG"] }],
      [for r in local.local_roles : { principal = local.gname["dev:${c.owner}:${r}"], privileges = ["USE_CATALOG", "BROWSE"] }],
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
  # ---------------------------------------------------------------------------
  domain_private_schemas = { for t in setproduct(local.env_keys, local.domain_keys, keys(local.dcfg.schemas)) :
    "domain:${t[0]}:${t[1]}/${t[2]}" => {
      catalog_key = "domain:${t[0]}:${t[1]}", catalog = "${t[0]}_${t[1]}", env = t[0], name = t[2]
      comment     = local.dcfg.schemas[t[2]].comment
      volumes     = try(local.dcfg.schemas[t[2]].volumes, [])
      tags        = { piq_layer = local.dcfg.schemas[t[2]].layer }
      grants = concat(
        [for role, b in try(local.matrix.domain[t[2]], {}) : { principal = local.gname["${t[0]}:${t[1]}:${role}"], privileges = local.bundle[b] }],
        t[2] == "event_log" ? [for p in local.domain_products[t[1]] : { principal = local.gname["product:${t[0]}:${p}"], privileges = local.bundle["R"] }] : [],
      )
    }
  }

  product_schemas = { for pr in setproduct(local.env_keys, local.product_keys) :
    "domain:${pr[0]}:${local.products[pr[1]].domain}/product_${pr[1]}" => {
      catalog_key = "domain:${pr[0]}:${local.products[pr[1]].domain}", catalog = "${pr[0]}_${local.products[pr[1]].domain}", env = pr[0]
      name        = "product_${pr[1]}"
      comment     = "Product ${pr[1]}: ${local.products[pr[1]].description}. Contract: ${local.products[pr[1]].contract}"
      volumes     = []
      tags = {
        piq_layer          = "PRODUCT"
        piq_product        = pr[1]
        piq_product_type   = local.products[pr[1]].type
        piq_product_status = local.products[pr[1]].status
      }
      grants = [for who, b in local.matrix.product : {
        principal  = who == "product_group" ? local.gname["product:${pr[0]}:${pr[1]}"] : local.gname["${pr[0]}:${local.products[pr[1]].domain}:${who}"]
        privileges = local.bundle[b]
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
      grants = flatten([for who, b in local.matrix.vault.schemas[t[1].kind] : (
        who == "loader" ? [{ principal = local.pg_env[t[0]].vault_write, privileges = local.bundle[b] }] :
        who == "engineer" ? [{ principal = local.pg_env[t[0]].vault_eng, privileges = local.bundle[try(local.matrix.vault.overrides[t[0]].engineer, b)] }] :
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
      grants      = [for r in local.consumers[c.owner].roles : { principal = local.gname["consumer:${c.owner}:${r}"], privileges = local.bundle[local.matrix.consumer_prep] }]
    }
  } if c.kind == "consumer"]...)

  anon_schemas = merge([for ck, c in local.catalogs : {
    for s in local.dcfg.anon_schemas : "${ck}/${s}" => {
      catalog_key = ck, catalog = c.name, env = c.env, name = s
      comment     = "Anonymized ${c.owner} data; never contains reversible personal data"
      volumes     = []
      tags        = { piq_layer = "ANON" }
      grants = concat(
        [{ principal = local.gname["writer:prd:${c.owner}"], privileges = local.bundle[local.matrix.anon.writer] }],
        [for r in local.local_roles : { principal = local.gname["dev:${c.owner}:${r}"], privileges = local.bundle[local.matrix.anon.dev_readers] }],
      )
    }
  } if c.kind == "anon"]...)

  platform_schemas = { for t in setproduct(local.env_keys, ["governance", "audit", "monitoring", "observability"]) :
    "platform:${t[0]}/${t[1]}" => {
      catalog_key = "platform:${t[0]}", catalog = "${t[0]}_platform", env = t[0], name = t[1]
      comment     = "Platform ${t[1]}"
      volumes     = []
      tags        = { piq_layer = "PLATFORM" }
      grants = t[1] == "governance" ? [
        { principal = "account users", privileges = ["USE_SCHEMA", "EXECUTE"] },
        ] : [
        { principal = local.pg_env[t[0]].mon, privileges = ["USE_SCHEMA", "SELECT"] },
        { principal = local.pg_env[t[0]].gov, privileges = ["USE_SCHEMA", "SELECT"] },
      ]
    }
  }

  sandbox_schemas = merge(
    { for u in try(local.sandbox.users, []) :
      "sandbox:dev/u_${replace(lower(split("@", u.upn)[0]), "/[^a-z0-9]/", "_")}" => {
        catalog_key = "sandbox:dev", catalog = "dev_sandbox", env = "dev"
        name        = "u_${replace(lower(split("@", u.upn)[0]), "/[^a-z0-9]/", "_")}"
        comment     = "Personal sandbox for ${u.upn} (${try(u.requested_via, "n/a")})"
        volumes     = []
        tags        = { piq_layer = "SCRATCH" }
        grants      = [{ principal = u.upn, privileges = ["ALL_PRIVILEGES"] }]
      }
    },
    { for e in try(local.exps.experiments, []) :
      "sandbox:prd/exp_${lower(e.name)}" => {
        catalog_key = "sandbox:prd", catalog = "prd_sandbox", env = "prd", name = "exp_${lower(e.name)}"
        comment     = "${e.description} | approved by ${e.approved_by} | ${e.ticket} | expires ${try(e.expires, "n/a")}"
        volumes     = []
        tags        = { piq_layer = "SCRATCH" }
        grants      = [for m in e.members : { principal = m, privileges = ["ALL_PRIVILEGES"] }]
      }
    },
  )

  schemas = merge(
    local.domain_private_schemas, local.product_schemas, local.vault_schemas,
    local.consumer_schemas, local.anon_schemas, local.platform_schemas, local.sandbox_schemas,
  )

  volumes = { for item in flatten([
    for sk, s in local.schemas : [for v in s.volumes : {
      key = "${sk}/${v}", catalog_key = s.catalog_key, catalog = s.catalog, schema_key = sk, schema = s.name, name = v, env = s.env
    }]
  ]) : item.key => item }

  granted_users = distinct(concat(
    [for u in try(local.sandbox.users, []) : u.upn],
    flatten([for e in try(local.exps.experiments, []) : e.members]),
  ))

  # ---------------------------------------------------------------------------
  # Warehouses per environment (workspace objects: no environment in the name).
  # ---------------------------------------------------------------------------
  wh = local.wsobj.warehouses

  warehouses = { for e in local.env_keys : e => merge(
    { for d in local.domain_keys : "piq-${local.hy[d]}-transform" => {
      size       = local.wh.domain.size, max_clusters = local.wh.domain.max_clusters, auto_stop_mins = local.wh.domain.auto_stop_mins
      can_use    = [for r in local.wh.domain.CAN_USE : local.gname["${e}:${d}:${r}"]]
      can_manage = concat([for r in local.wh.domain.CAN_MANAGE : local.gname["${e}:${d}:${r}"]], [local.pg_env[e].wsadmin])
      tags       = { piq_env = e, piq_domain = d, piq_workload = "transform" }
    } },
    { "piq-vault-load" = {
      size       = local.wh.vault.size, max_clusters = local.wh.vault.max_clusters, auto_stop_mins = local.wh.vault.auto_stop_mins
      can_use    = [local.pg_env[e].vault_write, local.pg_env[e].vault_eng]
      can_manage = [local.pg_env[e].wsadmin]
      tags       = { piq_env = e, piq_domain = "vault", piq_workload = "load" }
    } },
    { for c in local.consumer_keys : "piq-${local.hy[c]}-bi" => {
      size           = try(local.consumers[c].warehouse.size, local.wh.consumer.size)
      max_clusters   = try(local.consumers[c].warehouse.max_clusters, local.wh.consumer.max_clusters)
      auto_stop_mins = try(local.consumers[c].warehouse.auto_stop_mins, local.wh.consumer.auto_stop_mins)
      can_use        = [for r in local.consumers[c].roles : local.gname["consumer:${c}:${r}"]]
      can_manage     = [local.pg_env[e].wsadmin]
      tags           = { piq_env = e, piq_domain = c, piq_workload = "bi" }
    } if e == "prd" },
    { "piq-shared" = {
      size       = local.wh.shared.size, max_clusters = local.wh.shared.max_clusters, auto_stop_mins = local.wh.shared.auto_stop_mins
      can_use    = [local.pg_env[e].sandbox, local.pg_env[e].gov, local.pg_env[e].mon]
      can_manage = [local.pg_env[e].wsadmin]
      tags       = { piq_env = e, piq_domain = "shared", piq_workload = "shared" }
    } },
  ) }

  # env -> role -> group names across all producer domains (for policies, endpoints)
  role_groups = { for e in local.env_keys : e => {
    for r in local.roles : r => [for d in local.domain_keys : local.gname["${e}:${d}:${r}"]]
  } }

  # ---------------------------------------------------------------------------
  # Serverless usage policies: one per env x owner; principals may use it.
  # ---------------------------------------------------------------------------
  usage_scopes = local.cost.usage_policies.enabled ? merge(
    { for p in setproduct(local.env_keys, local.domain_keys) : "${p[0]}:${p[1]}" => {
      env        = p[0], owner = p[1], kind = "domain", name = "${local.prefix}-${p[0]}-${local.hy[p[1]]}"
      principals = concat([for r in local.roles : local.gname["${p[0]}:${p[1]}:${r}"]], [local.gname["writer:${p[0]}:${p[1]}"]])
    } },
    { for e in local.env_keys : "${e}:vault" => {
      env        = e, owner = "vault", kind = "vault", name = "${local.prefix}-${e}-vault"
      principals = [local.pg_env[e].vault_write, local.pg_env[e].vault_eng]
    } },
    { for c in local.consumer_keys : "prd:${c}" => {
      env        = "prd", owner = c, kind = "consumer", name = "${local.prefix}-prd-${local.hy[c]}"
      principals = [for r in local.consumers[c].roles : local.gname["consumer:${c}:${r}"]]
    } if contains(local.env_keys, "prd") },
    { for e in local.env_keys : "${e}:platform" => {
      env        = e, owner = "platform", kind = "platform", name = "${local.prefix}-${e}-platform"
      principals = [local.pg_env[e].gov, local.pg_env[e].mon]
    } },
    { for e in local.env_keys : "${e}:sandbox" => {
      env        = e, owner = "sandbox", kind = "sandbox", name = "${local.prefix}-${e}-sandbox"
      principals = [local.pg_env[e].sandbox]
    } },
  ) : {}

  # ---------------------------------------------------------------------------
  # Governed tags with generated values, and who may assign them.
  # ---------------------------------------------------------------------------
  generated_tag_values = {
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
  # Validation
  # ---------------------------------------------------------------------------
  sp_only_parents = [for n in values(local.nesting) : "${n.child} -> ${n.parent}"
    if n.why == "persona" && startswith(n.parent, "prd:") && contains(local.matrix.service_principal_only_in_prd, element(split(":", n.parent), 2))
  ]
  test_user_sp_only = [for m in values(local.test_user_memberships) : "${m.user} -> ${m.group}"
    if startswith(m.group, "prd:") && contains(local.matrix.service_principal_only_in_prd, element(split(":", m.group), 2))
  ]
  bad_consumers = flatten([for p, cfg in local.products : [
    for c in cfg.consumers : "${p}: ${c}" if c == cfg.domain || !(contains(local.domain_keys, c) || contains(local.consumer_keys, c))
  ]])
  bad_products  = [for p, cfg in local.products : p if !contains(local.domain_keys, cfg.domain)]
  bad_sar_masks = flatten([for sk, s in local.sars : [for m in s.unlocks : "${sk}: ${m}" if !contains(keys(local.masks), m)]])
  bad_mask_tags = [for mk, m in local.masks : mk if !contains(try(local.governed_tags[m.tag].values, []), m.value)]
  reserved_hits = setintersection(concat(local.domain_keys, local.consumer_keys), local.dcfg.reserved)
  key_overlap   = setintersection(local.domain_keys, local.consumer_keys)
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "prefix" { value = local.prefix }
output "platform" { value = local.platform }
output "environments" { value = local.environments }
output "env_keys" { value = local.env_keys }
output "domains" { value = local.domains }
output "domain_keys" { value = local.domain_keys }
output "consumers" { value = local.consumers }
output "consumer_keys" { value = local.consumer_keys }
output "products" { value = local.products }
output "vault" { value = local.vault }
output "roles" { value = local.roles }
output "groups" { value = local.groups }
output "nesting" { value = local.nesting }
output "user_memberships" { value = local.user_memberships }
output "test_users" { value = local.test_users }
output "test_user_memberships" { value = local.test_user_memberships }
output "service_principals" { value = local.service_principals }
output "sp_memberships" { value = local.sp_memberships }
output "group_workspace_assignments" { value = local.group_workspace_assignments }
output "sp_workspace_assignments" { value = local.sp_workspace_assignments }
output "catalogs" { value = local.catalogs }
output "storage_containers" { value = local.storage_containers }
output "catalog_grants" { value = local.catalog_grants }
output "schemas" { value = local.schemas }
output "volumes" { value = local.volumes }
output "granted_users" { value = local.granted_users }
output "warehouses" { value = local.warehouses }
output "role_groups" { value = local.role_groups }
output "platform_group_names" { value = { for k, g in local.platform_groups : trimprefix(k, "platform:") => g.name } }
output "usage_scopes" { value = local.usage_scopes }
output "governed_tags" { value = local.governed_tags }
output "masks" { value = local.masks }
output "abac_policies" { value = local.abac_policies }
output "workspace_objects" { value = local.wsobj }
output "cost" { value = local.cost }
output "sars" { value = local.sars }
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
    condition     = length(local.sp_only_parents) == 0 && length(local.test_user_sp_only) == 0
    error_message = "Humans may not join prd producer groups (service principals only): ${join(", ", concat(local.sp_only_parents, local.test_user_sp_only))}"
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
    error_message = "Product consumers must be another domain or a consumer domain: ${join(", ", local.bad_consumers)}"
  }
  precondition {
    condition     = length(local.unresolved_refs) == 0
    error_message = "Group references that resolve to no group: ${join(", ", local.unresolved_refs)}"
  }
  precondition {
    condition     = length(local.bad_sar_masks) == 0 && length(local.bad_mask_tags) == 0
    error_message = "SARs must unlock defined masks, and masks must use governed tag values: ${join(", ", concat(local.bad_sar_masks, local.bad_mask_tags))}"
  }
}
