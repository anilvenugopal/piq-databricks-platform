#!/usr/bin/env python3
"""
Validate a deployed target by running its stack's checks.

    python3 scripts/check.py <stack> --scope <scope> [--env <env>]

Loads stacks/<stack>/checks.py, which must define:

    CHECKS: list[Callable[[dict, Context], CheckResult]]

Each function receives the target's Terraform outputs and a Context (the target, plus the naming
output for it: what this run was supposed to create) and returns CheckResult(name, status, message)
where status is one of:
  PASS  - check succeeded
  FAIL  - check failed
  RETRY - transient condition; the runner will wait and retry

Exit codes:
  0  all checks passed
  1  one or more checks failed, or the target is invalid
"""
import argparse
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from util import tfrun  # noqa: E402
from util.scope import Target  # noqa: E402
from util.targets import context, resolve  # noqa: E402
from util.validation import Context, run_checks  # noqa: E402


def run(t: Target, ctx: Context) -> list[dict]:
    """Load and execute checks for a target. Called by apply.py and directly."""
    checks_file = ROOT / "stacks" / t.stack / "checks.py"
    if not checks_file.exists():
        print(f"  No checks.py for stack '{t.stack}': skipping validation.")
        return []

    spec = importlib.util.spec_from_file_location("stack_checks", checks_file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    checks = getattr(mod, "CHECKS", [])
    if not checks:
        print("  CHECKS list is empty.")
        return []

    if tfrun.init(t) != 0:
        return [{"name": "init", "status": "FAIL", "message": "terraform init failed"}]
    return run_checks(checks, tfrun.outputs(t), ctx, verbose=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("stack")
    ap.add_argument("--scope", required=True)
    ap.add_argument("--env")
    a = ap.parse_args()
    t, naming, problems = resolve(a.stack, a.env, a.scope)
    if problems:
        print("\n".join(f"ERROR: {p}" for p in problems), file=sys.stderr)
        return 1
    results = run(t, context(t, naming))
    return 0 if all(r["status"] == "PASS" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
