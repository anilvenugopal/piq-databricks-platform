#!/usr/bin/env python3
"""
Run terraform plan for one stack and print the diff.

    python3 scripts/plan.py <stack>

The plan file is written to stacks/<stack>/tfplan so that apply.py can
pick it up without re-planning. Exits non-zero if plan fails.
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(stack: str) -> int:
    from util.validation import resolve_stack
    if not resolve_stack(stack):
        return 1
    stack_dir = ROOT / "stacks" / stack

    plan_file = stack_dir / "tfplan"
    result = subprocess.run(
        [_tf(), f"-chdir={stack_dir}", "plan", f"-out={plan_file}"],
        check=False,
    )
    return result.returncode


def _tf() -> str:
    return os.environ.get("TF_BIN", "terraform")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: plan.py <stack>", file=sys.stderr)
        sys.exit(1)
    sys.exit(run(sys.argv[1]))
