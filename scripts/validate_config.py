#!/usr/bin/env python3
"""
Validate config/ before Terraform sees it. Runs in CI on every pull request.

    python3 scripts/validate_config.py [--config path/to/config]

Mirrors the preconditions in modules/naming and adds checks that are easier
here: product dependency cycles, environment promotion cycles, UPN formats,
file names, CIDR overlaps, domain shape and access limits.
"""
import argparse
import ipaddress
import pathlib
import re
import sys

import yaml

ap = argparse.ArgumentParser()
ap.add_argument("--config", default=str(pathlib.Path(__file__).resolve().parent.parent / "config"))
CFG = pathlib.Path(ap.parse_args().config)
errors: list[str] = []
err = errors.append

NAME = re.compile(r"^[a-z][a-z0-9_]{1,30}$")
KEBAB = re.compile(r"^[a-z][a-z0-9-]{1,40}$")
UPN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
TIERS = ("nonprod", "prod")


def load(rel):
    p = CFG / rel
    return (yaml.safe_load(p.read_text()) or {}) if p.exists() else {}


platform = load("platform.yaml")
dcfg = load("domains.yaml")
matrix = load("access_matrix.yaml")
wsobj = load("workspace_objects.yaml")
personas = load("personas.yaml")
spcfg = load("service_principals.yaml")
tagcfg = load("governed_tags.yaml")
sarcfg = load("sars.yaml")
testusers = load("test_users.yaml")

# --- platform and environments ----------------------------------------------
if not re.fullmatch(r"[a-z]{2,5}", str(platform.get("prefix", ""))):
    err("platform.prefix must be 2-5 lowercase letters")
if not re.fullmatch(r"[a-z0-9]{3,6}", str(platform.get("unique_suffix", ""))):
    err("platform.unique_suffix must be 3-6 lowercase alphanumerics")

env_cfg = platform.get("environments", {}) or {}
envs = sorted(env_cfg)
tier = {e: env_cfg[e].get("tier") for e in envs}
for e in envs:
    if not re.fullmatch(r"[a-z][a-z0-9]{1,7}", e):
        err(f"environment '{e}' must be 2-8 lowercase letters or digits")
    if tier[e] not in TIERS:
        err(f"environment '{e}': tier must be one of {', '.join(TIERS)} (got {tier[e]!r})")
prod_envs = [e for e in envs if tier[e] == "prod"]
nonprod_envs = [e for e in envs if tier[e] == "nonprod"]
if len(prod_envs) != 1:
    err(f"exactly one environment must have tier: prod (got {prod_envs})")
prod_env = prod_envs[0] if prod_envs else ""

promotes = {e: list(env_cfg[e].get("promotes_from", []) or []) for e in envs}
for e, srcs in promotes.items():
    for s in srcs:
        if s not in envs:
            err(f"environment '{e}': promotes_from names unknown environment '{s}'")
        elif s == e:
            err(f"environment '{e}': promotes_from lists itself")
    if not isinstance(env_cfg[e].get("allow_hotfix", False), bool):
        err(f"environment '{e}': allow_hotfix must be true or false")


def promotion_cycle(node, path):
    for nxt in promotes.get(node, ()):
        if nxt in path:
            return path[path.index(nxt):] + [nxt]
        found = promotion_cycle(nxt, path + [nxt])
        if found:
            return found
    return None


for e in envs:
    cyc = promotion_cycle(e, [e])
    if cyc:
        err(f"environment promotion cycle: {' -> '.join(cyc)}")
        break

vnets = []
for env, cfg in env_cfg.items():
    for key in ("vnet_cidr", "host_subnet_cidr", "container_subnet_cidr"):
        try:
            net = ipaddress.ip_network(cfg["network"][key])
            if key == "vnet_cidr":
                vnets.append((env, net))
        except Exception as e:  # noqa: BLE001
            err(f"{env}.network.{key}: {e}")
for i, (e1, n1) in enumerate(vnets):
    for e2, n2 in vnets[i + 1:]:
        if n1.overlaps(n2):
            err(f"VNet CIDRs of {e1} and {e2} overlap")

# --- domains and consumers --------------------------------------------------
reserved = set(dcfg.get("reserved", []))
domains = dcfg.get("domains", {}) or {}
for d, cfg in domains.items():
    if not NAME.match(d):
        err(f"domain '{d}' must be lowercase snake_case")
    if d in reserved:
        err(f"domain '{d}' is a reserved name")
    if not cfg.get("repo"):
        err(f"domain '{d}' needs a repo (its deployer trusts that repo)")
    if "admins" in cfg:
        err(f"domain '{d}': admins moved to config/entitlements/<env>/admins.yaml")

consumers = {p.stem: (yaml.safe_load(p.read_text()) or {}) for p in sorted((CFG / "consumers").glob("*.yaml"))}
for c, cfg in consumers.items():
    if not NAME.match(c):
        err(f"consumer '{c}' must be lowercase snake_case")
    if c in reserved:
        err(f"consumer '{c}' is a reserved name")
    if c in domains:
        err(f"'{c}' is both a domain and a consumer")
    if not UPN.match(str(cfg.get("lead", ""))):
        err(f"consumer '{c}' needs a lead UPN (owner of its groups)")
    if not cfg.get("roles"):
        err(f"consumer '{c}' needs at least one role")

vault = dcfg.get("vault", {})
if not vault.get("repo"):
    err("vault needs a repo")
for s in vault.get("sources", []):
    if not NAME.match(s):
        err(f"vault source '{s}' must be lowercase snake_case")

# --- domain shape and access ------------------------------------------------
roles_std = list(matrix.get("roles", []))
bundles = set(matrix.get("bundles", {}))
order = list(matrix.get("bundle_order", []))
ceiling = matrix.get("override_ceiling")
if ceiling not in order:
    err("access_matrix.override_ceiling must be one of bundle_order")
std_schemas = dcfg.get("schemas", {}) or {}
LAYERS = {s.get("layer") for s in std_schemas.values()} | {"INFO_MART", "REPORTING", "BUSINESS_VAULT", "SANDBOX", "AI", "EVENT_LOG", "ADMIN"}


def rank(b):
    return order.index(b) if b in order else 99


def load_domain_file(sub, d):
    p = CFG / sub / f"{d}.yaml"
    return (yaml.safe_load(p.read_text()) or {}) if p.exists() else {}


for sub in ("domain_shape", "domain_access"):
    for p in sorted((CFG / sub).glob("*.yaml")) if (CFG / sub).is_dir() else []:
        if p.stem not in domains:
            err(f"{sub}/{p.name} is for unknown domain '{p.stem}'")

domain_roles: dict[str, list[str]] = {}
domain_schemas: dict[str, set[str]] = {}
domain_personas: dict[str, dict] = {}
domain_sp_only: dict[str, set[str]] = {}
std_sp_only = set(matrix.get("service_principal_only_in_prod", []))
for d in domains:
    shape = load_domain_file("domain_shape", d)
    access = load_domain_file("domain_access", d)
    extra = shape.get("roles") or {}
    for r, c in extra.items():
        if not NAME.match(r):
            err(f"{d}: role '{r}' must be lowercase snake_case")
        if r in roles_std or r == "writer":
            err(f"{d}: role '{r}' collides with a standard or reserved role")
    domain_roles[d] = roles_std + sorted(extra)
    domain_sp_only[d] = set(std_sp_only) | {r for r, c in extra.items() if (c or {}).get("service_principal_only")}

    adds = (shape.get("schemas") or {}).get("add") or {}
    removes = (shape.get("schemas") or {}).get("remove") or []
    for sn, sc in adds.items():
        if not NAME.match(sn):
            err(f"{d}: schema '{sn}' must be lowercase snake_case")
        if sn in std_schemas or sn.startswith("product_"):
            err(f"{d}: schema '{sn}' collides with a standard schema or uses the product_ prefix")
        if (sc or {}).get("layer") not in LAYERS:
            err(f"{d}: schema '{sn}' needs a layer ({', '.join(sorted(x for x in LAYERS if x))})")
        if not (sc or {}).get("comment"):
            err(f"{d}: schema '{sn}' needs a comment")
    for sn in removes:
        if sn == "admin" or sn not in std_schemas:
            err(f"{d}: schema '{sn}' cannot be removed")
    domain_schemas[d] = ({s for s in std_schemas if s not in removes}) | set(adds)

    for sn, row in (access.get("schemas") or {}).items():
        if sn == "admin" or sn not in domain_schemas[d]:
            err(f"domain_access/{d}: access given for unknown or protected schema '{sn}'")
        for r, b in (row or {}).items():
            if r not in domain_roles[d]:
                err(f"domain_access/{d}.{sn}: unknown role '{r}'")
            for t in TIERS:
                v = b[t] if isinstance(b, dict) and t in b else b
                if isinstance(v, dict):
                    err(f"domain_access/{d}.{sn}.{r}: bundle must be a name or a {{nonprod, prod}} pair")
                elif v not in bundles:
                    err(f"domain_access/{d}.{sn}.{r}: unknown bundle '{v}'")
                elif rank(v) > rank(ceiling):
                    err(f"domain_access/{d}.{sn}.{r}: bundle '{v}' is above the ceiling '{ceiling}'")
    for r, b in (access.get("product") or {}).items():
        if r not in domain_roles[d] and r != "product_group":
            err(f"domain_access/{d}.product: unknown role '{r}'")
        for t in TIERS:
            v = b[t] if isinstance(b, dict) and t in b else b
            if isinstance(v, dict) or v not in bundles:
                err(f"domain_access/{d}.product.{r}: unknown bundle '{v}'")
            elif rank(v) > rank(ceiling):
                err(f"domain_access/{d}.product.{r}: bundle '{v}' is above the ceiling '{ceiling}'")
    for r in ((access.get("warehouse") or {}).get("CAN_USE") or []) + ((access.get("warehouse") or {}).get("CAN_MANAGE") or []):
        if r not in domain_roles[d]:
            err(f"domain_access/{d}.warehouse: unknown role '{r}'")

    domain_personas[d] = shape.get("personas") or {}
    for k in domain_personas[d]:
        if not KEBAB.match(k):
            err(f"{d}: persona '{k}' must be lowercase with hyphens")
        if k in (personas.get("personas") or {}):
            err(f"{d}: persona '{k}' collides with a global persona")
    for k in (access.get("personas") or {}):
        if k not in domain_personas[d]:
            err(f"domain_access/{d}: access given for undeclared persona '{k}'")

# --- products ---------------------------------------------------------------
products: dict[str, dict] = {}
for p in sorted((CFG / "products").glob("*.yaml")):
    if p.stem not in domains:
        err(f"product file {p.name} is for unknown domain '{p.stem}'")
    for name, cfg in ((yaml.safe_load(p.read_text()) or {}).get("products") or {}).items():
        if name in products:
            err(f"product '{name}' is defined more than once ({products[name]['domain']}, {p.stem})")
        if not NAME.match(name):
            err(f"product '{name}' must be lowercase snake_case")
        if cfg.get("type") not in ("data", "agent", "app"):
            err(f"product '{name}': type must be data, agent or app")
        if cfg.get("status", "draft") not in ("draft", "published", "deprecated"):
            err(f"product '{name}': status must be draft, published or deprecated")
        if "consumers" in cfg:
            err(f"product '{name}': consumers moved to config/entitlements/<env>/product_access.yaml")
        products[name] = {**cfg, "domain": p.stem}

# --- entitlements -----------------------------------------------------------
ENT = {e: {f: load(f"entitlements/{e}/{f}.yaml") for f in
           ("personas", "product_access", "sars", "sandboxes", "experiments", "admins")} for e in envs}
if (CFG / "entitlements").is_dir():
    for p in sorted((CFG / "entitlements").iterdir()):
        if p.is_dir() and p.name not in envs:
            err(f"entitlements/{p.name} is not a known environment")

# Domain dependency graph: consumer domain -> producing domain, over all environments. No cycles.
edges = {d: set() for d in domains}
for e in envs:
    for name, cs in ((ENT[e]["product_access"].get("products")) or {}).items():
        if name not in products:
            err(f"entitlements/{e}/product_access: unknown product '{name}'")
            continue
        for c in cs or []:
            if c == products[name]["domain"]:
                err(f"entitlements/{e}/product_access: product '{name}' lists its own domain as a consumer")
            elif c in consumers:
                if e != prod_env:
                    err(f"entitlements/{e}/product_access: consumer domain '{c}' can only be approved in {prod_env}")
            elif c not in domains:
                err(f"entitlements/{e}/product_access: unknown consumer '{c}'")
            else:
                edges[c].add(products[name]["domain"])


def cycle_from(node, path):
    for nxt in edges.get(node, ()):
        if nxt in path:
            return path[path.index(nxt):] + [nxt]
        found = cycle_from(nxt, path + [nxt])
        if found:
            return found
    return None


for d in domains:
    cyc = cycle_from(d, [d])
    if cyc:
        err(f"product dependency cycle: {' -> '.join(cyc)}")
        break

# --- access matrix ----------------------------------------------------------
roles = set(roles_std)


def check_bundle(where, b):
    for t in TIERS:
        v = b[t] if isinstance(b, dict) and t in b else b
        if isinstance(v, dict) or v not in bundles:
            err(f"{where}: unknown bundle '{v}'")


for schema, row in (matrix.get("domain") or {}).items():
    if schema not in std_schemas:
        err(f"access_matrix.domain: unknown schema '{schema}'")
    for role, b in (row or {}).items():
        if role not in roles:
            err(f"access_matrix.domain.{schema}: unknown role '{role}'")
        check_bundle(f"access_matrix.domain.{schema}.{role}", b)
for who, b in (matrix.get("product") or {}).items():
    if who not in roles and who != "product_group":
        err(f"access_matrix.product: unknown principal '{who}'")
    check_bundle(f"access_matrix.product.{who}", b)
for schema in (matrix.get("vault", {}).get("schemas") or {}):
    if schema != "stage" and schema not in vault.get("schemas", {}):
        err(f"access_matrix.vault: unknown vault schema '{schema}'")
for t in (matrix.get("vault", {}).get("overrides") or {}):
    if t not in TIERS:
        err(f"access_matrix.vault.overrides: key '{t}' must be a tier ({', '.join(TIERS)})")

# --- group references -------------------------------------------------------
pg_workspaces: dict[str, set[str]] = {k: set((g.get("workspaces") or {})) for k, g in (personas.get("platform_groups") or {}).items()}
for e in envs:
    pg_workspaces[f"{e}-workspace-admins"] = {e}
persona_keys = set(personas.get("personas", {}))

# Platform groups the platform itself relies on by name (modules/naming looks them up).
for required in ("mesh-admins", "metastore-admins", "mesh-governance", "platform-monitoring", "sandbox-users",
                 f"{prod_env}-experimenters"):
    if required not in pg_workspaces:
        err(f"personas.yaml platform_groups must define '{required}' (the platform refers to it by name)")


def check_ref(ref, owner, human, env=None, domain=None):
    """env / domain: the environment and domain a persona belongs to (None = unrestricted)."""
    parts = ref.split(":")
    if len(parts) == 1:
        if ref not in pg_workspaces:
            err(f"{owner}: unknown platform group '{ref}'")
        elif env and env not in pg_workspaces[ref]:
            err(f"{owner}: platform group '{ref}' is not assigned to the {env} workspace")
    elif parts[0] in envs and len(parts) == 3:
        e, dom, role = parts
        if env and e != env:
            err(f"{owner}: '{ref}' reaches another environment than {env}")
        if domain and dom != domain:
            err(f"{owner}: domain persona may only reference roles of '{domain}' ('{ref}')")
        if dom != "*" and dom not in domains:
            err(f"{owner}: unknown domain in '{ref}'")
        elif dom == "*":
            if not any(role in domain_roles[d] for d in domains):
                err(f"{owner}: no domain defines role '{role}' ('{ref}')")
        elif role not in domain_roles[dom]:
            err(f"{owner}: unknown role in '{ref}'")
        if human and e == prod_env:
            hit = [d for d in (domains if dom == "*" else [dom]) if d in domains and role in domain_sp_only[d]]
            if hit:
                err(f"{owner}: humans may not join {e} {role} groups ('{ref}'); use a service principal")
    elif parts[0] == "vault" and len(parts) == 3:
        if parts[1] not in envs or parts[2] not in ("engineer", "writer"):
            err(f"{owner}: bad vault reference '{ref}'")
        if env and parts[1] != env:
            err(f"{owner}: '{ref}' reaches another environment than {env}")
        if domain:
            err(f"{owner}: domain persona may not reference the vault ('{ref}')")
        if human and parts[2] == "writer":
            err(f"{owner}: humans may not join vault writer groups ('{ref}')")
    elif parts[0] == "consumer" and len(parts) == 3:
        if parts[1] not in consumers:
            err(f"{owner}: unknown consumer in '{ref}'")
        elif parts[2] not in consumers[parts[1]].get("roles", []):
            err(f"{owner}: unknown consumer role in '{ref}'")
    elif parts[0] == "persona" and len(parts) in (3, 4):
        e = parts[1]
        if e not in envs:
            err(f"{owner}: unknown environment in '{ref}'")
        elif len(parts) == 3 and parts[2] not in persona_keys:
            err(f"{owner}: unknown persona in '{ref}'")
        elif len(parts) == 4 and parts[3] not in domain_personas.get(parts[2], {}):
            err(f"{owner}: unknown domain persona in '{ref}'")
    else:
        err(f"{owner}: cannot parse group reference '{ref}'")


for pk, p in (personas.get("personas") or {}).items():
    if not KEBAB.match(pk):
        err(f"persona '{pk}' must be lowercase with hyphens")
    if "members" in p or "member_of" in p:
        err(f"persona {pk}: use access.<env>; members moved to config/entitlements/<env>/personas.yaml")
    access = p.get("access") or {}
    for e in access:
        if e not in envs:
            err(f"persona {pk}: access names unknown environment '{e}'")
    for e in envs:
        if e not in access:
            err(f"persona {pk}: access.{e} is missing (use [] for no access)")
        for ref in access.get(e) or []:
            check_ref(ref, f"persona {pk} ({e})", human=True, env=e)
for d, ps in domain_personas.items():
    acc = (load_domain_file("domain_access", d).get("personas") or {})
    for k in ps:
        a = (acc.get(k) or {}).get("access") or {}
        for e in envs:
            for ref in a.get(e) or []:
                check_ref(ref, f"persona {d}/{k} ({e})", human=True, env=e, domain=d)

for sk, s in (spcfg.get("service_principals") or {}).items():
    for ref in s.get("member_of", []):
        check_ref(ref, f"service principal {sk}", human=False)
if testusers.get("enabled"):
    for uk, u in (testusers.get("users") or {}).items():
        for ref in u.get("member_of", []):
            check_ref(ref, f"test user {uk}", human=True)

# --- persona assignments, admins, sandboxes, experiments ---------------------
for e in envs:
    for upn, ps in ((ENT[e]["personas"].get("users")) or {}).items():
        if not UPN.match(upn):
            err(f"entitlements/{e}/personas: '{upn}' is not a UPN")
        for pn in ps or []:
            if "/" in pn:
                d, k = pn.split("/", 1)
                if k not in domain_personas.get(d, {}):
                    err(f"entitlements/{e}/personas: '{upn}' has unknown domain persona '{pn}'")
            elif pn not in persona_keys:
                err(f"entitlements/{e}/personas: '{upn}' has unknown persona '{pn}'")
    for d, upns in ((ENT[e]["admins"].get("domains")) or {}).items():
        if d not in domains:
            err(f"entitlements/{e}/admins: unknown domain '{d}'")
        for u in upns or []:
            if not UPN.match(u):
                err(f"entitlements/{e}/admins: '{u}' is not a UPN")
    users = ENT[e]["sandboxes"].get("users") or []
    if users and tier[e] != "nonprod":
        err(f"entitlements/{e}/sandboxes: sandboxes belong in a nonprod environment")
    for u in users:
        if not UPN.match(u.get("upn", "")):
            err(f"entitlements/{e}/sandboxes: user '{u}' needs a valid upn")
    if "sandbox-users" in pg_workspaces and users and e not in pg_workspaces["sandbox-users"]:
        err(f"entitlements/{e}/sandboxes: platform group sandbox-users is not assigned to the {e} workspace")
    exps = ENT[e]["experiments"].get("experiments") or []
    if exps and tier[e] != "prod":
        err(f"entitlements/{e}/experiments: experiments belong in the prod environment")
    for x in exps:
        for field in ("name", "description", "members", "approved_by", "ticket"):
            if not x.get(field):
                err(f"experiment {x.get('name', '?')}: missing '{field}'")

# --- tags, masks, SARs ------------------------------------------------------
tags = tagcfg.get("tags", {})
masks = tagcfg.get("masks", {})
for mk, m in masks.items():
    t = tags.get(m.get("tag"))
    if not t:
        err(f"mask '{mk}': unknown tag '{m.get('tag')}'")
    elif t.get("values") != "generated" and m.get("value") not in t.get("values", []):
        err(f"mask '{mk}': '{m.get('value')}' is not a value of tag '{m['tag']}'")
for tk, t in tags.items():
    for a in t.get("assigners", []):
        if a.startswith("role:") and a[5:] not in roles:
            err(f"tag {tk}: unknown role assigner '{a}'")
        elif not a.startswith("role:") and a != "vault:writer" and a not in pg_workspaces:
            err(f"tag {tk}: unknown assigner '{a}'")
sars = sarcfg.get("sars") or {}
for sk, s in sars.items():
    if "members" in s:
        err(f"SAR '{sk}': members moved to config/entitlements/<env>/sars.yaml")
    for m in s.get("unlocks", []):
        if m not in masks:
            err(f"SAR '{sk}': unknown mask '{m}'")
for e in envs:
    for sk, refs in ((ENT[e]["sars"].get("members")) or {}).items():
        if sk not in sars:
            err(f"entitlements/{e}/sars: unknown SAR '{sk}'")
        for ref in refs or []:
            check_ref(ref, f"SAR {sk} ({e})", human=False)

# --- workspace objects ------------------------------------------------------
for k in ("CAN_USE", "CAN_MANAGE"):
    for r in wsobj.get("warehouses", {}).get("domain", {}).get(k, []):
        if r not in roles:
            err(f"workspace_objects.warehouses.domain.{k}: unknown role '{r}'")
for pk, p in (wsobj.get("cluster_policies") or {}).items():
    for r in p.get("CAN_USE", []):
        if r not in roles:
            err(f"cluster policy {pk}: unknown role '{r}'")

if errors:
    print("Config validation FAILED:")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
print(f"Config OK: {len(envs)} environments, {len(domains)} domains, {len(consumers)} consumer domains, "
      f"{len(products)} products, {len(personas.get('personas', {}))} personas, {len(sars)} SARs")
