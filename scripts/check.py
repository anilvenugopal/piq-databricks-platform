#!/usr/bin/env python3
"""
Validate a deployed stack by running its checks.

    python3 scripts/check.py <stack>

Loads stacks/<stack>/checks.py, which must define:

    CHECKS: list[Callable[[dict], CheckResult]]

Each function receives the stack's Terraform outputs as a dict and
returns a CheckResult(name, status, message) where status is one of:
  PASS  — check succeeded
  FAIL  — check failed
  RETRY — transient condition; the runner will wait and retry

Exit codes:
  0  all checks passed
  1  one or more checks failed
"""
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_outputs(stack_dir: Path) -> dict:
    tf = os.environ.get("TF_BIN", "terraform")
    try:
        raw = subprocess.check_output(
            [tf, f"-chdir={stack_dir}", "output", "-json"],
            stderr=subprocess.DEVNULL,
        )
        return {k: v["value"] for k, v in json.loads(raw).items()}
    except Exception:
        return {}


def run(stack: str) -> list[dict]:
    """Load and execute checks for a stack. Called by apply.py and directly."""
    stack_dir = ROOT / "stacks" / stack
    checks_file = stack_dir / "checks.py"

    if not checks_file.exists():
        print(f"  No checks.py for stack '{stack}' — skipping validation.")
        return []

    spec = importlib.util.spec_from_file_location("stack_checks", checks_file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    checks = getattr(mod, "CHECKS", [])
    if not checks:
        print("  CHECKS list is empty.")
        return []

    outputs = load_outputs(stack_dir)

    from util.validation import run_checks
    return run_checks(checks, outputs, verbose=True)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: check.py <stack>", file=sys.stderr)
        sys.exit(1)

    stack = sys.argv[1]
    from util.validation import resolve_stack
    if not resolve_stack(stack):
        sys.exit(1)

    results = run(stack)
    sys.exit(0 if all(r["status"] == "PASS" for r in results) else 1)
