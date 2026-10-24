"""
Evaluate modules/naming against a config directory and return its outputs as a dict.

One evaluator for everyone that needs the platform's derived names: the naming tests,
the mocked stack plans, the scope check and the post-apply checks. It runs the module in a
throwaway Terraform workspace (the module has no providers, so no cloud access is needed).

    from util.naming_eval import evaluate
    ok, outputs = evaluate(config_dir)                         # everything
    ok, outputs = evaluate(config_dir, "prd", "domain:claims")  # one scope's slice
"""
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

_HARNESS = """
module "n" {
  source      = "%s"
  config_dir  = "%s"
  environment = %s
  scope       = %s
}
output "n" { value = module.n }
"""


def _hcl(v):
    return "null" if v is None else json.dumps(v)


def evaluate(config_dir: Path, environment: str | None = None, scope: str | None = None):
    """Return (ok, outputs) or (False, error text)."""
    tf = os.environ.get("TF_BIN", "terraform")
    config_dir = Path(config_dir).resolve()
    work = Path(tempfile.mkdtemp(prefix="naming-"))
    try:
        (work / "main.tf").write_text(_HARNESS % (ROOT / "modules" / "naming", config_dir, _hcl(environment), _hcl(scope)))

        def run(*a):
            return subprocess.run([tf, f"-chdir={work}", *a], capture_output=True, text=True)

        init = run("init", "-no-color", "-input=false")
        if init.returncode:
            return False, init.stdout + init.stderr
        apply = run("apply", "-auto-approve", "-no-color", "-input=false")
        if apply.returncode:
            return False, apply.stdout + apply.stderr
        return True, json.loads(run("output", "-json", "n").stdout)
    finally:
        shutil.rmtree(work, ignore_errors=True)
