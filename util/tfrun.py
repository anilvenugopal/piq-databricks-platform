"""
Run Terraform for one deployment target through scripts/tf.sh, and read the results.

A target is (stack, environment, scope); see util/scope.py. Every wrapper (plan.py, apply.py,
check.py) goes through here so a target is always initialised, planned and applied the same way.
"""
import json
import subprocess
from pathlib import Path

from util.scope import Target, slug

ROOT = Path(__file__).resolve().parents[1]
TF_SH = ROOT / "scripts" / "tf.sh"


def tf_sh(t: Target, *args: str, capture: bool = False) -> subprocess.CompletedProcess:
    """scripts/tf.sh <stack> --scope S [--env E] <args>"""
    cmd = ["bash", str(TF_SH), t.stack, "--scope", t.scope]
    if t.env:
        cmd += ["--env", t.env]
    return subprocess.run(cmd + list(args), capture_output=capture, text=True, check=False)


def plan_path(t: Target) -> Path:
    """Where the saved plan of a target lives (stacks/<stack>/<env>-<scope>.tfplan, git-ignored)."""
    return ROOT / "stacks" / t.stack / f"{t.env or 'shared'}-{slug(t.scope)}.tfplan"


def init(t: Target) -> int:
    return tf_sh(t, "init", "-input=false").returncode


def plan(t: Target, out: Path) -> int:
    return tf_sh(t, "plan", "-input=false", f"-out={out}").returncode


def show_text(t: Target, planfile: Path) -> str:
    return tf_sh(t, "show", "-no-color", str(planfile), capture=True).stdout


def show_json(t: Target, planfile: Path) -> dict:
    r = tf_sh(t, "show", "-json", str(planfile), capture=True)
    return json.loads(r.stdout)


def apply(t: Target, planfile: Path) -> int:
    return tf_sh(t, "apply", "-input=false", str(planfile)).returncode


def outputs(t: Target) -> dict:
    r = tf_sh(t, "output", "-json", capture=True)
    try:
        return {k: v["value"] for k, v in json.loads(r.stdout).items()}
    except Exception:
        return {}
