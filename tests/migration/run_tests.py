#!/usr/bin/env python3
"""
Test scripts/migrate_foundation_state.py offline: build a synthetic OLD state of stack 10 (both
environments in one state), run the migration in file mode, and check what ends up where.

    python3 tests/migration/run_tests.py
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "migrate_foundation_state.py"
failures: list[str] = []


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name)
    if not cond:
        failures.append(f"{name} {detail}")


PROVIDER = 'provider["registry.terraform.io/hashicorp/azurerm"]'


def resource(rtype, name, keys, mode="managed"):
    return {"mode": mode, "type": rtype, "name": name, "provider": PROVIDER,
            "instances": [{"index_key": k, "schema_version": 0, "attributes": {"id": f"/{rtype}/{k}"}} for k in keys]}


def old_state(extra=None):
    return {
        "version": 4, "terraform_version": "1.9.8", "serial": 7, "lineage": "11111111-2222-3333-4444-555555555555",
        "outputs": {}, "check_results": None,
        "resources": [
            resource("azurerm_resource_group", "env", ["dev", "prd"]),
            resource("azurerm_virtual_network", "env", ["dev", "prd"]),
            resource("azurerm_subnet", "dbw", ["dev-host", "dev-container", "prd-host", "prd-container"]),
            resource("azurerm_databricks_workspace", "env", ["dev", "prd"]),
            resource("azurerm_storage_account", "lake", ["dev", "prd"]),
            resource("azurerm_storage_container", "catalog", ["dev-claims", "dev-policy-financial", "prd-claims", "prd-policy-financial"]),
            resource("azurerm_key_vault", "env", ["dev", "prd"]),
            *(extra or []),
        ],
    }


def run(state, *args):
    work = Path(tempfile.mkdtemp(prefix="mig-test-"))
    f = work / "in.tfstate"
    f.write_text(json.dumps(state))
    out = work / "out"
    r = subprocess.run([sys.executable, str(SCRIPT), "--state-file", str(f), "--out-dir", str(out), *args], capture_output=True, text=True)
    return r, out


def addresses(path):
    s = json.loads(path.read_text())
    return {f'{r["type"]}.{r["name"]}["{i["index_key"]}"]' for r in s["resources"] for i in r["instances"]}


print("migration of the stack 10 state")
r, out = run(old_state())
check("the script succeeds offline", r.returncode == 0, r.stdout + r.stderr)
if r.returncode == 0:
    dev, prd = addresses(out / "dev.tfstate"), addresses(out / "prd.tfstate")
    check("dev gets exactly its own resources", all(a.split('["')[1].startswith("dev") for a in dev) and len(dev) == 8, str(sorted(dev)))
    check("prd gets exactly its own resources", all(a.split('["')[1].startswith("prd") for a in prd) and len(prd) == 8, str(sorted(prd)))
    check("subnets and containers named <env>-x go to that environment",
          'azurerm_subnet.dbw["dev-host"]' in dev and 'azurerm_storage_container.catalog["prd-claims"]' in prd)
    check("nothing is in both", not (dev & prd))
    check("the resource group is not moved", not any("resource_group" in a for a in dev | prd))
    check("the resource-group import commands for bootstrap are printed",
          "azurerm_resource_group.env[\"dev\"]" in r.stdout and "azurerm_resource_group.env[\"prd\"]" in r.stdout and "resourceGroups/rg-piq-dev" in r.stdout, r.stdout)
    check("only the two resource groups are left behind", "left in the old state: 2 instances" in r.stdout, r.stdout)

r, out = run(old_state([resource("azurerm_public_ip", "nat", ["shared"])]))
check("a resource that belongs to no environment stops the migration", r.returncode == 1 and "belong to no environment" in r.stderr, r.stdout + r.stderr)

print()
if failures:
    print(f"{len(failures)} FAILED")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("all migration tests passed")
