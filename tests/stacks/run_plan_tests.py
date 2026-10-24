#!/usr/bin/env python3
"""
Mocked plans of every stack: catches wiring and type errors without cloud access.

    python3 tests/stacks/run_plan_tests.py [stack ...]     # TF_BIN=tofu to use OpenTofu

For each stack: copy it to a temp dir, write a .tftest.hcl that mocks every provider and
overrides terraform_remote_state with values derived from the naming module, then run
`<tf> test` with one `plan` per deployment target the stack supports (every environment,
every domain, every scope; see stacks/<stack>/stack.yaml and util/scope.py).
Needs the providers installable (registry access, or a filesystem mirror).
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from util.naming_eval import evaluate  # noqa: E402
from util.scope import stack_scopes  # noqa: E402

TF = os.environ.get("TF_BIN", "terraform")
STACKS = ["10-foundation", "20-identity", "25-access", "30-account", "40-unity-catalog",
          "50-workspace", "55-ai-platform", "60-governance", "70-observability"]


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


ok, n = evaluate(ROOT / "config")
if not ok:
    sys.exit(n)
envs = n["env_keys"]
domains = n["domain_keys"]
prod_env = n["prod_env"]

remote = {
    "foundation": {
        "workspaces": {e: {"resource_id": f"/subscriptions/0/rg/dbw-{e}", "workspace_id": str(1000 + i),
                           "url": f"https://adb-{1000 + i}.azuredatabricks.net", "rg": f"rg-{e}"}
                       for i, e in enumerate(envs)},
        "storage": {e: {"name": f"stpiq{e}lake", "id": f"/storage/{e}", "dfs_endpoint": f"https://stpiq{e}lake.dfs.core.windows.net/"} for e in envs},
        "access_connectors": {e: f"/subscriptions/0/ac-{e}" for e in envs},
        "key_vaults": {e: {"id": f"/kv/{e}", "uri": f"https://kv-{e}.vault.azure.net/"} for e in envs},
    },
    "account": {"usage_policy_ids": {k: f"policy-{i}" for i, k in enumerate(n["usage_scopes"])}},
    "workspace": {"warehouse_ids": {w: f"wh-{j}" for j, w in enumerate(n["warehouses"][envs[0]])}},
}

MOCK_BLOCKS = {
    "databricks": """
mock_provider "databricks" {
  mock_data "databricks_account_iam_external_group_v2" { defaults = { internal_id = "101" } }
  mock_data "databricks_account_iam_external_service_principal_v2" { defaults = { internal_id = "102" } }
  mock_data "databricks_account_iam_external_user_v2" { defaults = { internal_id = "103" } }
}
""",
    "databricks.account": 'mock_provider "databricks" {\n  alias = "account"\n}\n',
    "azurerm": """
mock_provider "azurerm" {
  mock_data "azurerm_client_config" { defaults = { object_id = "00000000-0000-0000-0000-000000000001" } }
  mock_data "azurerm_resource_group" { defaults = { location = "eastus2" } }
}
""",
    "azuread": """
mock_provider "azuread" {
  mock_data "azuread_client_config" { defaults = { object_id = "00000000-0000-0000-0000-000000000001" } }
  mock_data "azuread_domains" { defaults = { domains = [{ domain_name = "example.onmicrosoft.com", initial = true }] } }
  mock_data "azuread_service_principal" { defaults = { object_id = "00000000-0000-0000-0000-000000000002" } }
  mock_data "azuread_user" { defaults = { object_id = "00000000-0000-0000-0000-000000000003" } }
  mock_data "azuread_group" { defaults = { object_id = "00000000-0000-0000-0000-000000000004" } }
}
""",
    "random": 'mock_provider "random" {}\n',
}


def mocks_for(text):
    out = ""
    if "databricks/databricks" in text:
        out += MOCK_BLOCKS["databricks"]
        if 'alias      = "account"' in text:
            out += MOCK_BLOCKS["databricks.account"]
    for p in ("azurerm", "azuread", "random"):
        if f"hashicorp/{p}" in text:
            out += MOCK_BLOCKS[p]
    return out


def targets(stack):
    """(environment or None, scope) for every target of the stack."""
    out = []
    for kind in stack_scopes(stack):
        if kind == "shared":
            out.append((None, "shared"))
        elif kind in ("env", "access"):
            envs_here = [prod_env] if stack == "70-observability" else envs
            out += [(e, kind) for e in envs_here]
        elif kind == "domain":
            out += [(e, f"domain:{d}") for e in envs for d in domains]
    return out


def run_block(env, scope):
    name = ("shared" if env is None else f"{env}_{scope}").replace(":", "_")
    vars_ = f'    scope = "{scope}"\n' + (f'    environment = "{env}"\n' if env else "")
    return f'run "{name}" {{\n  command = plan\n  variables {{\n{vars_}  }}\n}}\n'


failures = []
for stack in (sys.argv[1:] or STACKS):
    src = ROOT / "stacks" / stack
    text = "".join(p.read_text() for p in src.glob("*.tf"))
    tmp = pathlib.Path(tempfile.mkdtemp(prefix=f"plan-{stack}-"))
    shutil.copytree(ROOT, tmp / "repo", ignore=shutil.ignore_patterns(".git", ".venv", ".terraform*", "*.tfstate*", "__pycache__"))
    sdir = tmp / "repo" / "stacks" / stack
    (sdir / "providers.tf").write_text((sdir / "providers.tf").read_text().replace('backend "azurerm" {}', ""))
    mocks = mocks_for(text)
    for name, key in (("foundation", "foundation"), ("account", "account"), ("workspace", "workspace")):
        for suffix in ("", "_other"):
            if f'data "terraform_remote_state" "{name}{suffix}"' in text:
                target = f"data.terraform_remote_state.{name}{suffix}"
                values = hcl(remote[key], 2)
                if suffix:  # for_each instances: override every environment key
                    for e in envs:
                        mocks += (f'override_data {{\n  target = {target}["{e}"]\n'
                                  f'  values = {{ outputs = {values} }}\n}}\n')
                else:
                    mocks += f'override_data {{\n  target = {target}\n  values = {{ outputs = {values} }}\n}}\n'
    runs = targets(stack)
    for env, scope in runs:
        mocks += run_block(env, scope)
    (sdir / "tests").mkdir(exist_ok=True)
    (sdir / "tests" / "plan.tftest.hcl").write_text(mocks)
    init = subprocess.run([TF, f"-chdir={sdir}", "init", "-input=false", "-no-color"], capture_output=True, text=True)
    if init.returncode:
        print(f"== {stack}: SKIPPED (providers not installable here)")
        continue
    r = subprocess.run([TF, f"-chdir={sdir}", "test", "-no-color", "-verbose"], capture_output=True, text=True)
    good = r.returncode == 0
    planned = r.stdout.count(" will be created") + r.stdout.count(" will be read during apply")
    print(f"== {stack}: {'plan OK' if good else 'FAILED'} ({len(runs)} targets, {planned} resources and data sources planned)")
    if not good:
        failures.append(stack)
        print(r.stdout[-3500:] + r.stderr[-2000:])
    shutil.rmtree(tmp, ignore_errors=True)

if failures:
    sys.exit(f"mocked plans failed: {', '.join(failures)}")
