#!/usr/bin/env python3
"""
Mocked plans of every stack: catches wiring and type errors without cloud access.

    python3 tests/stacks/run_plan_tests.py [stack ...]     # TF_BIN=tofu to use OpenTofu

For each stack: copy it to a temp dir, write a .tftest.hcl that mocks every
provider and overrides terraform_remote_state with values derived from the
naming module, then run `<tf> test` with command = plan. Needs the providers
installable (registry access, or a filesystem mirror).
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
TF = os.environ.get("TF_BIN", "terraform")
STACKS = ["10-foundation", "20-identity", "30-account", "40-unity-catalog",
          "50-workspace", "55-ai-platform", "60-governance", "70-observability"]


def naming_outputs():
    work = pathlib.Path(tempfile.mkdtemp(prefix="naming-"))
    (work / "main.tf").write_text(
        f'module "n" {{\n  source = "{ROOT}/modules/naming"\n  config_dir = "{ROOT}/config"\n}}\n'
        'output "n" { value = module.n }\n')
    for args in (["init", "-input=false", "-no-color"], ["apply", "-auto-approve", "-input=false", "-no-color"]):
        r = subprocess.run([TF, f"-chdir={work}", *args], capture_output=True, text=True)
        if r.returncode:
            sys.exit(r.stdout + r.stderr)
    out = subprocess.run([TF, f"-chdir={work}", "output", "-json", "n"], capture_output=True, text=True)
    return json.loads(out.stdout)


def hcl(v, ind=0):
    """Render a JSON value as an HCL literal."""
    pad = "  " * ind
    if isinstance(v, dict):
        if not v:
            return "{}"
        inner = ",\n".join(f'{pad}  {json.dumps(k)} = {hcl(x, ind + 1)}' for k, x in v.items())
        return "{\n" + inner + "\n" + pad + "}"
    if isinstance(v, list):
        return "[" + ", ".join(hcl(x, ind) for x in v) + "]"
    return json.dumps(v)


n = naming_outputs()
envs = n["env_keys"]
remote = {
    "foundation": {
        "workspaces": {e: {"resource_id": f"/subscriptions/0/rg/dbw-{e}", "workspace_id": str(1000 + i),
                           "url": f"https://adb-{1000 + i}.azuredatabricks.net", "rg": f"rg-{e}"}
                       for i, e in enumerate(envs)},
        "storage": {e: {"name": f"stpiq{e}lake", "id": f"/storage/{e}", "dfs_endpoint": f"https://stpiq{e}lake.dfs.core.windows.net/"} for e in envs},
        "access_connectors": {e: f"/subscriptions/0/ac-{e}" for e in envs},
        "key_vaults": {e: {"id": f"/kv/{e}", "uri": f"https://kv-{e}.vault.azure.net/"} for e in envs},
    },
    "identity": {
        "groups": {k: {"name": g["name"], "object_id": f"00000000-0000-0000-0000-{i:012d}"} for i, (k, g) in enumerate(n["groups"].items())},
        "service_principals": {k: {"display_name": s["display_name"], "client_id": f"c-{i}", "object_id": f"o-{i}"} for i, (k, s) in enumerate(n["service_principals"].items())},
        "users": {u: f"u-{i}" for i, u in enumerate(n["granted_users"])},
    },
    "account": {"usage_policy_ids": {k: f"policy-{i}" for i, k in enumerate(n["usage_scopes"])}},
    "workspace": {"warehouse_ids": {e: {w: f"wh-{e}-{j}" for j, w in enumerate(n["warehouses"][e])} for e in envs}},
}
state_for = {"foundation": "foundation", "identity": "identity", "account": "account", "workspace": "workspace"}

MOCK_BLOCKS = {
    "databricks": """
mock_provider "databricks" {
  mock_data "databricks_account_iam_external_group_v2" { defaults = { internal_id = "101" } }
  mock_data "databricks_account_iam_external_service_principal_v2" { defaults = { internal_id = "102" } }
  mock_data "databricks_account_iam_external_user_v2" { defaults = { internal_id = "103" } }
}
""",
    "databricks.account": 'mock_provider "databricks" {\n  alias = "account"\n}\n',
    "databricks.dev": 'mock_provider "databricks" {\n  alias = "dev"\n}\n',
    "databricks.prd": 'mock_provider "databricks" {\n  alias = "prd"\n}\n',
    "azurerm": """
mock_provider "azurerm" {
  mock_data "azurerm_client_config" { defaults = { object_id = "00000000-0000-0000-0000-000000000001" } }
}
""",
    "azuread": """
mock_provider "azuread" {
  mock_data "azuread_client_config" { defaults = { object_id = "00000000-0000-0000-0000-000000000001" } }
  mock_data "azuread_domains" { defaults = { domains = [{ domain_name = "example.onmicrosoft.com", initial = true }] } }
  mock_data "azuread_service_principal" { defaults = { object_id = "00000000-0000-0000-0000-000000000002" } }
}
""",
    "random": 'mock_provider "random" {}\n',
}


def mocks_for(text):
    out = ""
    if "databricks/databricks" in text:
        aliases = [a for a in ("account", "dev", "prd") if f'alias      = "{a}"' in text or f'alias     = "{a}"' in text or f'alias = "{a}"' in text]
        if not aliases or 'provider "databricks" {\n  host       = local' in text:
            out += MOCK_BLOCKS["databricks"]
        for a in aliases:
            out += MOCK_BLOCKS[f"databricks.{a}"]
    for p in ("azurerm", "azuread", "random"):
        if f"hashicorp/{p}" in text:
            out += MOCK_BLOCKS[p]
    return out


failures = []
for stack in (sys.argv[1:] or STACKS):
    src = ROOT / "stacks" / stack
    text = "".join(p.read_text() for p in src.glob("*.tf"))
    tmp = pathlib.Path(tempfile.mkdtemp(prefix=f"plan-{stack}-"))
    shutil.copytree(ROOT, tmp / "repo", ignore=shutil.ignore_patterns(".git", ".terraform*", "*.tfstate*"))
    sdir = tmp / "repo" / "stacks" / stack
    (sdir / "providers.tf").write_text((sdir / "providers.tf").read_text().replace('backend "azurerm" {}', ""))
    mocks = mocks_for(text)
    for name, key in state_for.items():
        if f'data "terraform_remote_state" "{name}"' in text:
            mocks += (f'override_data {{\n  target = data.terraform_remote_state.{name}\n'
                      f'  values = {{ outputs = {hcl(remote[key], 2)} }}\n}}\n')
    mocks += 'run "plan" {\n  command = plan\n}\n'
    (sdir / "tests").mkdir(exist_ok=True)
    (sdir / "tests" / "plan.tftest.hcl").write_text(mocks)
    init = subprocess.run([TF, f"-chdir={sdir}", "init", "-input=false", "-no-color"], capture_output=True, text=True)
    if init.returncode:
        print(f"== {stack}: SKIPPED (providers not installable here)")
        continue
    r = subprocess.run([TF, f"-chdir={sdir}", "test", "-no-color", "-verbose"], capture_output=True, text=True)
    ok = r.returncode == 0
    planned = r.stdout.count(" will be created") + r.stdout.count(" will be read during apply")
    print(f"== {stack}: {'plan OK' if ok else 'FAILED'} ({planned} resources and data sources planned)")
    if not ok:
        failures.append(stack)
        print(r.stdout[-3000:] + r.stderr[-2000:])
    shutil.rmtree(tmp, ignore_errors=True)

sys.exit(1 if failures else 0)
