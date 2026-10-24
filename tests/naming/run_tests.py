#!/usr/bin/env python3
"""
Tests for modules/naming and scripts/validate_config.py.

    python3 tests/naming/run_tests.py            # uses `terraform`
    TF_BIN=tofu python3 tests/naming/run_tests.py

Positive case: evaluates the module against config/ and checks derived names,
nesting, grants, bindings, warehouses and ABAC exceptions.
Partition case: evaluates the module once per scope and proves that every item is
owned by exactly one scope (this is what stops one domain's deploy from touching
another's).
Domain-additions case: a copy of config/ where one domain adds a schema, a role and a
persona; checks they appear for that domain only.
Negative cases: copies config/, breaks one rule, and checks that BOTH the
module (a precondition) and the validator reject it with the right message.
Needs no cloud credentials: the module has no providers.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from util.naming_eval import evaluate  # noqa: E402

failures: list[str] = []

def validator(config_dir: pathlib.Path):
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "validate_config.py"), "--config", str(config_dir)],
                       capture_output=True, text=True)
    return r.returncode == 0, r.stdout + r.stderr


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name)
    if not cond:
        failures.append(f"{name} {detail}")


# ---------------------------------------------------------------------------
print("positive: config/ as committed")
ok, n = evaluate(ROOT / "config")
if not ok:
    print(n)
    sys.exit(1)

g = {k: v["name"] for k, v in n["groups"].items()}
check("group name uses hyphenated domain", g["prd:policy_financial:producer"] == "piq-prd-policy-financial-producer")
check("product group has no domain in name", g["product:prd:loss_ratio"] == "piq-prd-product-loss-ratio")
check("consumer group is prod-only and led", g["consumer:exec_reporting:analyst"] == "piq-prd-exec-reporting-analyst"
      and n["groups"]["consumer:exec_reporting:analyst"]["lead"] == "exec.reporting.lead@example.com")
check("tiers drive the rules", n["prod_env"] == "prd" and n["nonprod_envs"] == ["dev"])

# personas are environment-scoped
check("persona groups exist per environment", g["persona:dev:data-engineer"] == "piq-dev-persona-data-engineer"
      and g["persona:prd:data-engineer"] == "piq-prd-persona-data-engineer")
nest = n["nesting"]
check("dev persona nested into dev producer role", "persona:dev:data-engineer>dev:claims:producer" in nest)
check("prd persona is read-only in prd", "persona:prd:data-engineer>prd:claims:analyst" in nest
      and "persona:prd:data-engineer>prd:claims:producer" not in nest)
check("a persona never reaches the other environment",
      not any(k.startswith("persona:dev:") and ">prd:" in k for k in nest)
      and not any(k.startswith("persona:prd:") and ">dev:" in k for k in nest))
check("workspace admins are generated per environment", g["platform:prd-workspace-admins"] == "piq-prd-workspace-admins")

# approvals and memberships are entitlements, in the access outputs only
anest = n["access_nesting"]
check("derived producer nested into base product (access)", "prd:profitability:producer>product:prd:loss" in anest)
check("consumer nested into derived product (access)", "consumer:exec_reporting:analyst>product:prd:loss_ratio" in anest)
check("consumer NOT nested into products it was not approved for", "consumer:exec_reporting:analyst>product:prd:loss" not in anest)
check("consumer domains absent from dev product groups", not any(k.startswith("consumer:") and ":dev:" in k for k in anest))
check("SAR membership from entitlements", "consumer:exec_reporting:analyst>sar:prd:financial_metrics" in anest)
check("infrastructure nesting holds no approvals", not any(v["why"] != "persona" for v in nest.values()))
check("persona members come from entitlements",
      any(k.startswith("prd|") and k.endswith(">persona:prd:platform-admin") for k in n["access_user_memberships"]))

cat = n["catalogs"]
check("anon catalog bound read-only to nonprod", cat["anon:prd:claims"]["readonly_envs"] == ["dev"])
check("only domains with anon: true get anon catalogs", "anon:prd:policy_financial" not in cat)
check("storage containers use hyphens", "policy-financial" in n["storage_containers"]["prd"])

grants = {x["principal"]: x["privileges"] for x in n["catalog_grants"]["domain:prd:claims"]}
check("product group gets USE_CATALOG without BROWSE", grants["piq-prd-product-loss"] == ["USE_CATALOG"])
check("domain admin gets O at catalog level", grants["piq-prd-claims-dbadmin"] == ["ALL_PRIVILEGES", "MANAGE"])

ps = n["schemas"]["domain:prd:claims/product_loss"]
check("product schema tagged", ps["tags"] == {"piq_layer": "PRODUCT", "piq_product": "loss",
                                             "piq_product_type": "data", "piq_product_status": "published"})
check("product group reads its schema", any(x["principal"] == "piq-prd-product-loss" and "SELECT" in x["privileges"] for x in ps["grants"]))
check("product group has no grant on private schemas",
      all(x["principal"] != "piq-prd-product-loss" for x in n["schemas"]["domain:prd:claims/business_vault"]["grants"]))
eng_dev = [x for x in n["schemas"]["vault:dev/raw_vault"]["grants"] if x["principal"] == "piq-dev-vault-engineer"][0]
eng_prd = [x for x in n["schemas"]["vault:prd/raw_vault"]["grants"] if x["principal"] == "piq-prd-vault-engineer"][0]
check("vault engineers write in nonprod only", "MODIFY" in eng_dev["privileges"] and "MODIFY" not in eng_prd["privileges"])
check("stage schema per source", "vault:prd/stage_billing" in n["schemas"])

wh = n["warehouses"]
check("warehouse names carry no environment", "piq-claims-transform" in wh["dev"] and "piq-claims-transform" in wh["prd"])
check("consumer warehouse only in prod", "piq-exec-reporting-bi" in wh["prd"] and "piq-exec-reporting-bi" not in wh["dev"])
check("domain warehouse limited to that domain",
      wh["prd"]["piq-claims-transform"]["can_use"] == ["piq-prd-claims-producer", "piq-prd-claims-analyst", "piq-prd-claims-ai"])

pol = n["abac_policies"]["domain:prd:claims|ssn"]
check("PII mask exempts SAR and writer only", sorted(pol["except"]) == ["piq-prd-claims-writer", "piq-prd-sar-claimant-pii"])
check("financial mask exempts financial SAR", "piq-prd-sar-financial-metrics" in n["abac_policies"]["domain:prd:profitability|financial_amount"]["except"])
check("mask condition uses governed tag", pol["condition"] == "has_tag_value('pii', 'ssn')")

sp = n["service_principals"]["deploy:prd:claims"]
check("deployer trusts its domain repo prd environment", sp["github_subjects"] == [f"repo:{n['platform']['github']['org']}/piq-claims:environment:prd"])
check("generated tag values", n["governed_tags"]["piq_product"]["values"] == ["earned_premium", "loss", "loss_ratio"])
okv, msg = validator(ROOT / "config")
check("validator accepts committed config", okv, msg)


# ---------------------------------------------------------------------------
print("partition: every item belongs to exactly one scope")
PARTITIONED = ["groups", "nesting", "access_nesting", "access_user_memberships", "access_test_user_memberships",
               "service_principals", "sp_memberships", "group_workspace_assignments", "sp_workspace_assignments",
               "catalogs", "schemas", "volumes", "usage_scopes", "governed_tags", "abac_policies", "test_users"]


def keys_of(out):
    ks = set()
    for name in PARTITIONED:
        ks |= {f"{name}:{k}" for k in out[name]}
    ks |= {f"warehouses:{e}:{w}" for e, ws in out["warehouses"].items() for w in ws}
    ks |= {f"catalog_grants:{k}" for k in out["catalog_grants"]}
    return ks


full = keys_of(n)
seen: dict[str, str] = {}
dupes: list[str] = []
scopes = [(None, "shared")] + [(e, s) for e in n["env_keys"] for s in ["env", "access"] + [f"domain:{d}" for d in n["domain_keys"]]]
for env, scope in scopes:
    ok2, out = evaluate(ROOT / "config", env, scope)
    if not ok2:
        check(f"scope {env}/{scope} evaluates", False, str(out)[-300:])
        continue
    label = f"{env}/{scope}"
    for k in keys_of(out):
        if k in seen:
            dupes.append(f"{k} in {seen[k]} and {label}")
        seen[k] = label
    if scope.startswith("domain:"):
        owned = [v for name in ("groups", "catalogs", "schemas", "service_principals", "abac_policies") for v in out[name].values()]
        check(f"{label} holds only its own domain's items",
              all(v["scope"] == scope and v["env"] == env for v in owned), str([v for v in owned if v["scope"] != scope][:2]))
check("scopes are disjoint", not dupes, str(dupes[:3]))
check("scopes together cover everything", set(seen) == full, str(sorted(full - set(seen))[:3]))
okd, outd = evaluate(ROOT / "config", "prd", "domain:claims")
check("domain scope contains only that domain's catalog",
      okd and set(outd["catalogs"]) == {"domain:prd:claims", "anon:prd:claims"}, str(outd)[:200] if not okd else str(list(outd["catalogs"])))
oke, oute = evaluate(ROOT / "config", "prd", "env")
check("env scope holds the vault, platform and sandbox catalogs",
      oke and {"vault:prd", "platform:prd", "sandbox:prd", "consumer:prd:exec_reporting"} <= set(oute["catalogs"])
      and not any(k.startswith("domain:") for k in oute["catalogs"]))
check("env scope creates every storage container of its environment",
      oke and "claims" in oute["storage_containers"]["prd"] and oute["storage_containers"]["dev"] == [])


# ---------------------------------------------------------------------------
print("domain additions: extra schema, role and persona for one domain")


def edit(path, fn):
    data = yaml.safe_load(path.read_text())
    fn(data)
    path.write_text(yaml.safe_dump(data, sort_keys=False))


def write_yaml(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(data, sort_keys=False))


tmp = pathlib.Path(tempfile.mkdtemp(prefix="cfg-"))
shutil.copytree(ROOT / "config", tmp / "config")
c = tmp / "config"
write_yaml(c / "domain_shape" / "claims.yaml", {
    "schemas": {"add": {"adjuster_notes": {"layer": "INFO_MART", "comment": "Adjuster notes"}}, "remove": ["ai"]},
    "roles": {"adjuster": {"description": "Claims adjusters"}},
    "personas": {"adjuster-analyst": {"description": "Adjuster who analyses claims data"}},
})
write_yaml(c / "domain_access" / "claims.yaml", {
    "schemas": {"adjuster_notes": {"producer": "RWC", "adjuster": "R"}, "reporting": {"analyst": "R"},
                "info_mart": {"analyst": {"nonprod": "RW", "prod": "R"}}},
    "warehouse": {"CAN_USE": ["adjuster"]},
    "personas": {"adjuster-analyst": {"access": {"dev": ["dev:claims:adjuster", "sandbox-users"], "prd": ["prd:claims:adjuster"]}}},
})
okc, nc = evaluate(c)
check("domain additions evaluate", okc, str(nc)[-400:])
if okc:
    gc = {k: v["name"] for k, v in nc["groups"].items()}
    check("extra role group exists for that domain in every environment",
          gc.get("dev:claims:adjuster") == "piq-dev-claims-adjuster" and gc.get("prd:claims:adjuster") == "piq-prd-claims-adjuster")
    check("other domains do not get the extra role", "dev:profitability:adjuster" not in gc)
    check("domain persona group is named per environment and domain",
          gc.get("persona:prd:claims:adjuster-analyst") == "piq-prd-persona-claims-adjuster-analyst")
    check("domain persona nests only into its own domain",
          "persona:prd:claims:adjuster-analyst>prd:claims:adjuster" in nc["nesting"])
    check("extra schema exists only for that domain", "domain:prd:claims/adjuster_notes" in nc["schemas"]
          and "domain:prd:profitability/adjuster_notes" not in nc["schemas"])
    check("removed schema is gone for that domain only", "domain:prd:claims/ai" not in nc["schemas"]
          and "domain:prd:profitability/ai" in nc["schemas"])
    notes = {x["principal"]: x["privileges"] for x in nc["schemas"]["domain:prd:claims/adjuster_notes"]["grants"]}
    check("extra role is granted on the extra schema", "SELECT" in notes["piq-prd-claims-adjuster"] and "MODIFY" not in notes["piq-prd-claims-adjuster"])
    rep = {x["principal"]: x["privileges"] for x in nc["schemas"]["domain:prd:claims/reporting"]["grants"]}
    rep_other = {x["principal"]: x["privileges"] for x in nc["schemas"]["domain:prd:profitability/reporting"]["grants"]}
    check("access override tightens one domain only", "MODIFY" not in rep["piq-prd-claims-analyst"] and "MODIFY" in rep_other["piq-prd-profitability-analyst"])
    mart_dev = {x["principal"]: x["privileges"] for x in nc["schemas"]["domain:dev:claims/info_mart"]["grants"]}
    mart_prd = {x["principal"]: x["privileges"] for x in nc["schemas"]["domain:prd:claims/info_mart"]["grants"]}
    check("a bundle can differ by tier", "MODIFY" in mart_dev["piq-dev-claims-analyst"] and "MODIFY" not in mart_prd["piq-prd-claims-analyst"])
    check("extra role can use the domain warehouse", "piq-prd-claims-adjuster" in nc["warehouses"]["prd"]["piq-claims-transform"]["can_use"])
    check("wildcard expands only to domains that have the role",
          "persona:dev:data-analyst>dev:claims:analyst" in nc["nesting"])
okv2, msg2 = validator(c)
check("validator accepts the additions", okv2, msg2)
shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
def negative(title, mutate, expect):
    print(f"negative: {title}")
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="cfg-"))
    shutil.copytree(ROOT / "config", tmp / "config")
    mutate(tmp / "config")
    ok, out = evaluate(tmp / "config")
    check("module rejects", (not ok) and expect["module"] in " ".join(str(out).split()), str(out)[-400:])
    okv, msg = validator(tmp / "config")
    check("validator rejects", (not okv) and expect["validator"] in msg, msg[-400:])
    shutil.rmtree(tmp, ignore_errors=True)


negative("persona nested into a prod producer group",
         lambda c: edit(c / "personas.yaml", lambda d: d["personas"]["team-lead"]["access"]["prd"].append("prd:claims:producer")),
         {"module": "Humans may not join prod-tier", "validator": "humans may not join prd producer"})
negative("persona in dev reaching a prd group",
         lambda c: edit(c / "personas.yaml", lambda d: d["personas"]["team-lead"]["access"]["dev"].append("prd:claims:analyst")),
         {"module": "A persona may only reference its own environment", "validator": "reaches another environment"})
negative("persona assigned a workspace of another environment",
         lambda c: edit(c / "personas.yaml", lambda d: d["personas"]["team-lead"]["access"]["prd"].append("sandbox-users")),
         {"module": "A persona may only reference its own environment", "validator": "is not assigned to the prd workspace"})
negative("person assigned an unknown persona",
         lambda c: edit(c / "entitlements" / "dev" / "personas.yaml", lambda d: d["users"].update({"jane@premiumiq.com": ["no-such-persona"]})),
         {"module": "Persona assignments that resolve to no group", "validator": "unknown persona"})
negative("consumer domain approved in a nonprod environment",
         lambda c: edit(c / "entitlements" / "dev" / "product_access.yaml", lambda d: d["products"]["loss_ratio"].append("exec_reporting")),
         {"module": "Product consumers must be", "validator": "can only be approved in prd"})
negative("sandboxes in the prod environment",
         lambda c: write_yaml(c / "entitlements" / "prd" / "sandboxes.yaml", {"users": [{"upn": "jane@premiumiq.com"}]}),
         {"module": "Entitlements in the wrong environment tier", "validator": "sandboxes belong in a nonprod environment"})
negative("product consumer that does not exist",
         lambda c: edit(c / "entitlements" / "dev" / "product_access.yaml", lambda d: d["products"]["loss"].append("marketing")),
         {"module": "Product consumers must be", "validator": "unknown consumer"})
negative("duplicate product name across domains",
         lambda c: edit(c / "products" / "profitability.yaml", lambda d: d["products"].update({"loss": d["products"]["loss_ratio"]})),
         {"module": "Product names must be unique", "validator": "defined more than once"})
negative("reserved domain key",
         lambda c: edit(c / "domains.yaml", lambda d: d["domains"].update({"vault": d["domains"]["claims"]})),
         {"module": "reserved", "validator": "reserved"})
negative("SAR unlocking an unknown mask",
         lambda c: edit(c / "sars.yaml", lambda d: d["sars"]["claimant_pii"]["unlocks"].append("passport")),
         {"module": "SARs must unlock defined masks", "validator": "unknown mask"})
negative("group reference that resolves to nothing",
         lambda c: edit(c / "personas.yaml", lambda d: d["personas"]["team-lead"]["access"]["prd"].append("prd:marketing:analyst")),
         {"module": "resolve to no group", "validator": "unknown domain"})
negative("two production environments",
         lambda c: edit(c / "platform.yaml", lambda d: d["environments"]["dev"].update({"tier": "prod"})),
         {"module": "Exactly one environment must have tier: prod", "validator": "exactly one environment must have tier: prod"})


def shape(c, fn):
    path = c / "domain_shape" / "claims.yaml"
    data = yaml.safe_load(path.read_text()) if path.exists() else {}
    fn(data)
    write_yaml(path, data)


def access(c, fn):
    path = c / "domain_access" / "claims.yaml"
    data = yaml.safe_load(path.read_text()) if path.exists() else {}
    fn(data)
    write_yaml(path, data)


negative("domain role that collides with a standard role",
         lambda c: shape(c, lambda d: d.setdefault("roles", {}).update({"analyst": {"description": "x"}})),
         {"module": "collides with a standard or reserved role", "validator": "collides with a standard or reserved role"})
negative("domain schema that collides with a standard schema",
         lambda c: shape(c, lambda d: d.setdefault("schemas", {}).setdefault("add", {}).update({"reporting": {"layer": "REPORTING", "comment": "x"}})),
         {"module": "collides with a standard schema", "validator": "collides with a standard schema"})
negative("removing the admin schema",
         lambda c: shape(c, lambda d: d.setdefault("schemas", {}).update({"remove": ["admin"]})),
         {"module": "cannot be removed", "validator": "cannot be removed"})
negative("domain access above the ceiling",
         lambda c: access(c, lambda d: d.setdefault("schemas", {}).update({"reporting": {"analyst": "O"}})),
         {"module": "bundle above the ceiling", "validator": "above the ceiling"})
negative("domain access for an unknown role",
         lambda c: access(c, lambda d: d.setdefault("schemas", {}).update({"reporting": {"nobody": "R"}})),
         {"module": "unknown role nobody", "validator": "unknown role 'nobody'"})
negative("domain persona nested into another domain",
         lambda c: (shape(c, lambda d: d.setdefault("personas", {}).update({"adjuster-analyst": {"description": "x"}})),
                    access(c, lambda d: d.setdefault("personas", {}).update({"adjuster-analyst": {"access": {"dev": ["dev:profitability:analyst"], "prd": []}}}))),
         {"module": "a domain persona only its own domain's roles", "validator": "domain persona may only reference roles of 'claims'"})
negative("human in an extra service-principal-only role in prd",
         lambda c: (shape(c, lambda d: d.setdefault("roles", {}).update({"loader": {"description": "x", "service_principal_only": True}})),
                    edit(c / "personas.yaml", lambda d: d["personas"]["team-lead"]["access"]["prd"].append("prd:claims:loader"))),
         {"module": "Humans may not join prod-tier", "validator": "humans may not join prd loader groups"})

print()
if failures:
    print(f"{len(failures)} FAILED")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("all naming tests passed")
