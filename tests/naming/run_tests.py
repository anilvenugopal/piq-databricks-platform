#!/usr/bin/env python3
"""
Tests for modules/naming and scripts/validate_config.py.

    python3 tests/naming/run_tests.py            # uses `terraform`
    TF_BIN=tofu python3 tests/naming/run_tests.py

Positive case: evaluates the module against config/ and checks derived names,
nesting, grants, bindings, warehouses and ABAC exceptions.
Negative cases: copies config/, breaks one rule, and checks that BOTH the
module (a precondition) and the validator reject it with the right message.
Needs no cloud credentials: the module has no providers.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
TF = os.environ.get("TF_BIN", "terraform")
failures: list[str] = []

HARNESS = """
module "n" {
  source     = "%s"
  config_dir = "%s"
}
output "n" { value = module.n }
"""


def evaluate(config_dir: pathlib.Path):
    """Return (ok, outputs_or_error_text)."""
    work = pathlib.Path(tempfile.mkdtemp(prefix="naming-"))
    (work / "main.tf").write_text(HARNESS % (ROOT / "modules" / "naming", config_dir))
    run = lambda *a: subprocess.run([TF, f"-chdir={work}", *a], capture_output=True, text=True)
    init = run("init", "-no-color", "-input=false")
    if init.returncode:
        return False, init.stdout + init.stderr
    apply = run("apply", "-auto-approve", "-no-color", "-input=false")
    if apply.returncode:
        return False, apply.stdout + apply.stderr
    out = run("output", "-json", "n")
    shutil.rmtree(work, ignore_errors=True)
    return True, json.loads(out.stdout)


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
check("consumer group is prd-only and led", g["consumer:exec_reporting:analyst"] == "piq-prd-exec-reporting-analyst"
      and n["groups"]["consumer:exec_reporting:analyst"]["lead"] == "exec.reporting.lead@example.com")

nest = n["nesting"]
check("derived producer nested into base product", "prd:profitability:producer>product:prd:loss" in nest)
check("consumer nested into derived product", "consumer:exec_reporting:analyst>product:prd:loss_ratio" in nest)
check("consumer NOT nested into products it was not approved for", "consumer:exec_reporting:analyst>product:prd:loss" not in nest)
check("consumer domains absent from dev product groups", not any(k.startswith("consumer:") and ":dev:" in k for k in nest))
check("SAR membership from sars.yaml", "consumer:exec_reporting:analyst>sar:prd:financial_metrics" in nest)

cat = n["catalogs"]
check("anon catalog bound read-only to dev", cat["anon:prd:claims"]["readonly_envs"] == ["dev"])
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
check("vault engineers write in dev only", "MODIFY" in eng_dev["privileges"] and "MODIFY" not in eng_prd["privileges"])
check("stage schema per source", "vault:prd/stage_billing" in n["schemas"])

wh = n["warehouses"]
check("warehouse names carry no environment", "piq-claims-transform" in wh["dev"] and "piq-claims-transform" in wh["prd"])
check("consumer warehouse only in prd", "piq-exec-reporting-bi" in wh["prd"] and "piq-exec-reporting-bi" not in wh["dev"])
check("domain warehouse limited to that domain",
      wh["prd"]["piq-claims-transform"]["can_use"] == ["piq-prd-claims-producer", "piq-prd-claims-analyst", "piq-prd-claims-ai"])

pol = n["abac_policies"]["domain:prd:claims|ssn"]
check("PII mask exempts SAR and writer only", sorted(pol["except"]) == ["piq-prd-claims-writer", "piq-prd-sar-claimant-pii"])
check("financial mask exempts financial SAR", "piq-prd-sar-financial-metrics" in n["abac_policies"]["domain:prd:profitability|financial_amount"]["except"])
check("mask condition uses governed tag", pol["condition"] == "has_tag_value('pii', 'ssn')")

sp = n["service_principals"]["deploy:prd:claims"]
check("deployer trusts its domain repo prd environment", sp["github_subjects"] == ["repo:your-github-org/piq-claims:environment:prd"])
check("generated tag values", n["governed_tags"]["piq_product"]["values"] == ["earned_premium", "loss", "loss_ratio"])
okv, msg = validator(ROOT / "config")
check("validator accepts committed config", okv, msg)


# ---------------------------------------------------------------------------
def negative(title, mutate, expect):
    print(f"negative: {title}")
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="cfg-"))
    shutil.copytree(ROOT / "config", tmp / "config")
    mutate(tmp / "config")
    ok, out = evaluate(tmp / "config")
    check("module rejects", (not ok) and expect["module"] in str(out), str(out)[-400:])
    okv, msg = validator(tmp / "config")
    check("validator rejects", (not okv) and expect["validator"] in msg, msg[-400:])
    shutil.rmtree(tmp, ignore_errors=True)


def edit(path, fn):
    data = yaml.safe_load(path.read_text())
    fn(data)
    path.write_text(yaml.safe_dump(data, sort_keys=False))


negative("persona nested into a prd producer group",
         lambda c: edit(c / "personas.yaml", lambda d: d["personas"]["team-lead"]["member_of"].append("prd:claims:producer")),
         {"module": "Humans may not join prd producer", "validator": "humans may not join prd producer"})
negative("product consumer that does not exist",
         lambda c: edit(c / "products" / "claims.yaml", lambda d: d["products"]["loss"]["consumers"].append("marketing")),
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
         lambda c: edit(c / "personas.yaml", lambda d: d["personas"]["team-lead"]["member_of"].append("prd:marketing:analyst")),
         {"module": "resolve to no group", "validator": "unknown domain"})

print()
if failures:
    print(f"{len(failures)} FAILED")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("all naming tests passed")
