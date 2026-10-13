#!/usr/bin/env python3
"""
Validate config/ before Terraform sees it. Runs in CI on every pull request.

    python3 scripts/validate_config.py [--config path/to/config]

Mirrors the preconditions in modules/naming and adds checks that are easier
here: product dependency cycles, UPN formats, file names, CIDR overlaps.
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
UPN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


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
sandbox = load("sandbox_users.yaml")
exps = load("experiments.yaml")
testusers = load("test_users.yaml")

# --- platform ---------------------------------------------------------------
if not re.fullmatch(r"[a-z]{2,5}", str(platform.get("prefix", ""))):
    err("platform.prefix must be 2-5 lowercase letters")
if not re.fullmatch(r"[a-z0-9]{3,6}", str(platform.get("unique_suffix", ""))):
    err("platform.unique_suffix must be 3-6 lowercase alphanumerics")
envs = sorted(platform.get("environments", {}))
if envs != ["dev", "prd"]:
    err(f"environments must be exactly dev and prd (got {envs})")

vnets = []
for env, cfg in platform.get("environments", {}).items():
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
    for u in cfg.get("admins", []) or []:
        if not UPN.match(u):
            err(f"domain '{d}' admin '{u}' is not a UPN")

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
        products[name] = {**cfg, "domain": p.stem}

for name, cfg in products.items():
    for c in cfg.get("consumers", []) or []:
        if c == cfg["domain"]:
            err(f"product '{name}' lists its own domain as a consumer")
        elif c not in domains and c not in consumers:
            err(f"product '{name}': unknown consumer '{c}'")

# Domain dependency graph: consumer domain -> producing domain. No cycles.
edges = {d: set() for d in domains}
for name, cfg in products.items():
    for c in cfg.get("consumers", []) or []:
        if c in domains:
            edges[c].add(cfg["domain"])


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
roles = set(matrix.get("roles", []))
bundles = set(matrix.get("bundles", {}))
for schema, row in (matrix.get("domain") or {}).items():
    if schema not in dcfg.get("schemas", {}):
        err(f"access_matrix.domain: unknown schema '{schema}'")
    for role, b in (row or {}).items():
        if role not in roles:
            err(f"access_matrix.domain.{schema}: unknown role '{role}'")
        if b not in bundles:
            err(f"access_matrix.domain.{schema}: unknown bundle '{b}'")
for who, b in (matrix.get("product") or {}).items():
    if who not in roles and who != "product_group":
        err(f"access_matrix.product: unknown principal '{who}'")
    if b not in bundles:
        err(f"access_matrix.product: unknown bundle '{b}'")
for schema in (matrix.get("vault", {}).get("schemas") or {}):
    if schema != "stage" and schema not in vault.get("schemas", {}):
        err(f"access_matrix.vault: unknown vault schema '{schema}'")

# --- group references -------------------------------------------------------
platform_groups = set(personas.get("platform_groups", {}))
persona_keys = set(personas.get("personas", {}))
sp_only = set(matrix.get("service_principal_only_in_prd", []))


def check_ref(ref, owner, human):
    parts = ref.split(":")
    if len(parts) == 1:
        if ref not in platform_groups:
            err(f"{owner}: unknown platform group '{ref}'")
    elif parts[0] in envs and len(parts) == 3:
        env, dom, role = parts
        if dom != "*" and dom not in domains:
            err(f"{owner}: unknown domain in '{ref}'")
        if role not in roles:
            err(f"{owner}: unknown role in '{ref}'")
        if human and env == "prd" and role in sp_only:
            err(f"{owner}: humans may not join prd {role} groups ('{ref}'); use a service principal")
    elif parts[0] == "vault" and len(parts) == 3:
        if parts[1] not in envs or parts[2] not in ("engineer", "writer"):
            err(f"{owner}: bad vault reference '{ref}'")
        if human and parts[2] == "writer":
            err(f"{owner}: humans may not join vault writer groups ('{ref}')")
    elif parts[0] == "consumer" and len(parts) == 3:
        if parts[1] not in consumers:
            err(f"{owner}: unknown consumer in '{ref}'")
        elif parts[2] not in consumers[parts[1]].get("roles", []):
            err(f"{owner}: unknown consumer role in '{ref}'")
    elif parts[0] == "persona" and len(parts) == 2:
        if parts[1] not in persona_keys:
            err(f"{owner}: unknown persona in '{ref}'")
    else:
        err(f"{owner}: cannot parse group reference '{ref}'")


for pk, p in (personas.get("personas") or {}).items():
    for ref in p.get("member_of", []):
        check_ref(ref, f"persona {pk}", human=True)
    for u in p.get("members", []) or []:
        if not UPN.match(u):
            err(f"persona {pk}: '{u}' is not a UPN")
for sk, s in (spcfg.get("service_principals") or {}).items():
    for ref in s.get("member_of", []):
        check_ref(ref, f"service principal {sk}", human=False)
if testusers.get("enabled"):
    for uk, u in (testusers.get("users") or {}).items():
        for ref in u.get("member_of", []):
            check_ref(ref, f"test user {uk}", human=True)

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
        elif not a.startswith("role:") and a != "vault:writer" and a not in platform_groups:
            err(f"tag {tk}: unknown assigner '{a}'")
for sk, s in (sarcfg.get("sars") or {}).items():
    for m in s.get("unlocks", []):
        if m not in masks:
            err(f"SAR '{sk}': unknown mask '{m}'")
    for env, refs in (s.get("members") or {}).items():
        if env not in envs:
            err(f"SAR '{sk}': unknown environment '{env}'")
        for ref in refs or []:
            check_ref(ref, f"SAR {sk}", human=False)

# --- workspace objects ------------------------------------------------------
for k in ("CAN_USE", "CAN_MANAGE"):
    for r in wsobj.get("warehouses", {}).get("domain", {}).get(k, []):
        if r not in roles:
            err(f"workspace_objects.warehouses.domain.{k}: unknown role '{r}'")
for pk, p in (wsobj.get("cluster_policies") or {}).items():
    for r in p.get("CAN_USE", []):
        if r not in roles:
            err(f"cluster policy {pk}: unknown role '{r}'")

# --- sandboxes and experiments ----------------------------------------------
for u in sandbox.get("users", []) or []:
    if not UPN.match(u.get("upn", "")):
        err(f"sandbox user '{u}' needs a valid upn")
for e in exps.get("experiments", []) or []:
    for field in ("name", "description", "members", "approved_by", "ticket"):
        if not e.get(field):
            err(f"experiment {e.get('name', '?')}: missing '{field}'")

if errors:
    print("Config validation FAILED:")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
print(f"Config OK: {len(domains)} domains, {len(consumers)} consumer domains, {len(products)} products, "
      f"{len(personas.get('personas', {}))} personas, {len(sarcfg.get('sars', {}))} SARs")
