#!/usr/bin/env python3
"""
Validate config/*.yaml before Terraform ever sees it. Runs in CI on every PR.

Checks (each maps to a design rule in docs/ARCHITECTURE.md):
  * names are lowercase snake/kebab and not reserved
  * every role in the access matrix exists; every bundle exists
  * no persona is nested into a prd producer group (prd writes = SPs only)
  * persona / SP references resolve to real groups
  * CIDRs are valid and do not overlap across environments
  * sandbox users look like UPNs; experiments carry approver, ticket, members
  * governed tag assigners resolve; masks reference values of the `pii` tag
"""
import ipaddress
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CFG = ROOT / "config"
errors: list[str] = []


def load(name):
    return yaml.safe_load((CFG / name).read_text()) or {}


def err(msg):
    errors.append(msg)


platform = load("platform.yaml")
domains = load("domains.yaml")
matrix = load("access_matrix.yaml")
personas = load("personas.yaml")
sps = load("service_principals.yaml")
tags = load("governed_tags.yaml")
sandbox = load("sandbox_users.yaml")
exps = load("experiments.yaml")
wsobj = load("workspace_objects.yaml")

NAME = re.compile(r"^[a-z][a-z0-9_]{1,30}$")
UPN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

prefix = platform.get("prefix", "")
if not re.fullmatch(r"[a-z]{2,5}", prefix):
    err(f"platform.prefix '{prefix}' must be 2-5 lowercase letters")
if not re.fullmatch(r"[a-z0-9]{3,6}", str(platform.get("unique_suffix", ""))):
    err("platform.unique_suffix must be 3-6 lowercase alphanumerics")

envs = list(platform.get("environments", {}))
if sorted(envs) != ["dev", "prd"]:
    err(f"environments must be exactly dev and prd for this repo version (got {envs})")

reserved = set(domains.get("reserved", []))
domain_keys = list(domains.get("domains", {}))
for d in domain_keys:
    if not NAME.match(d):
        err(f"domain key '{d}' must be lowercase snake_case")
    if d in reserved:
        err(f"domain key '{d}' is reserved")

roles = set(matrix["roles"])
bundles = set(matrix["bundles"])
for schema, row in matrix["matrix"].items():
    if schema not in domains["schemas"]:
        err(f"access matrix references unknown schema '{schema}'")
    for role, bundle in row.items():
        if role not in roles:
            err(f"access matrix: unknown role '{role}' in schema '{schema}'")
        if bundle not in bundles:
            err(f"access matrix: unknown bundle '{bundle}' in schema '{schema}'")

platform_groups = set(personas.get("platform_groups", {}))
sp_only = set(matrix.get("service_principal_only_in_prd", []))


def check_ref(ref, owner, human):
    parts = ref.split(":")
    if len(parts) == 3:
        env, dom, role = parts
        if env not in envs:
            err(f"{owner}: unknown env in '{ref}'")
        if dom != "*" and dom not in domain_keys:
            err(f"{owner}: unknown domain in '{ref}'")
        if role not in roles:
            err(f"{owner}: unknown role in '{ref}'")
        if human and env == "prd" and role in sp_only:
            err(f"{owner}: humans may not join prd {role} groups ('{ref}'); use a service principal")
    elif ref not in platform_groups:
        err(f"{owner}: unknown platform group '{ref}'")


for pk, p in personas.get("personas", {}).items():
    for ref in p.get("member_of", []):
        check_ref(ref, f"persona {pk}", human=True)
    for upn in p.get("members", []) or []:
        if not UPN.match(upn):
            err(f"persona {pk}: '{upn}' is not a UPN")

for sk, s in sps.get("service_principals", {}).items():
    for ref in s.get("member_of", []):
        check_ref(ref, f"service principal {sk}", human=False)
    for env in s.get("workspaces", {}):
        if env not in envs:
            err(f"service principal {sk}: unknown workspace env '{env}'")

nets = []
for env, cfg in platform.get("environments", {}).items():
    for key in ("vnet_cidr", "host_subnet_cidr", "container_subnet_cidr"):
        try:
            nets.append((env, key, ipaddress.ip_network(cfg["network"][key])))
        except Exception as e:  # noqa: BLE001
            err(f"{env}.network.{key}: {e}")
vnets = [(e, n) for e, k, n in nets if k == "vnet_cidr"]
for i, (e1, n1) in enumerate(vnets):
    for e2, n2 in vnets[i + 1:]:
        if n1.overlaps(n2):
            err(f"VNet CIDRs of {e1} and {e2} overlap")

for u in sandbox.get("users", []) or []:
    if not UPN.match(u.get("upn", "")):
        err(f"sandbox user '{u}' needs a valid upn")

for e in exps.get("experiments", []) or []:
    for field in ("name", "description", "members", "approved_by", "ticket"):
        if not e.get(field):
            err(f"experiment {e.get('name', '?')}: missing '{field}'")
    if e.get("name") and not NAME.match(e["name"]):
        err(f"experiment name '{e['name']}' must be lowercase snake_case")

pii_values = set(tags.get("tags", {}).get("pii", {}).get("values", []))
for k in tags.get("masks", {}):
    if k not in pii_values:
        err(f"mask '{k}' is not a value of the pii tag")
for tk, t in tags.get("tags", {}).items():
    for a in t.get("assigners", []):
        if a.startswith("role:"):
            if a[5:] not in roles:
                err(f"tag {tk}: unknown role assigner '{a}'")
        elif a not in platform_groups:
            err(f"tag {tk}: unknown platform group assigner '{a}'")

for kind in ("sql_warehouses", "cluster_policies"):
    for k, obj in wsobj.get(kind, {}).items():
        for perm in ("CAN_USE", "CAN_MANAGE"):
            for r in obj.get(perm, []):
                if r not in roles and r != "sandbox":
                    err(f"{kind}.{k}.{perm}: unknown role '{r}'")

if errors:
    print("Config validation FAILED:")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
print(f"Config OK: {len(domain_keys)} domains, {len(envs)} environments, "
      f"{len(personas.get('personas', {}))} personas, {len(sps.get('service_principals', {}))} service principals")
