#!/usr/bin/env python3
"""
Plan, confirm, apply, validate, and audit one stack.

    python3 scripts/apply.py <stack>           # interactive
    python3 scripts/apply.py <stack> --yes     # non-interactive (CI)

Exit codes:
  0  apply succeeded and all checks passed
  1  plan or apply failed, or checks failed after retries
  2  user declined at confirmation prompt
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIT_FILE = ROOT / "audit" / "runs.jsonl"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("stack")
    ap.add_argument("--yes", "-y", action="store_true",
                    help="skip confirmation prompt (for CI)")
    args = ap.parse_args()

    stack = args.stack
    from util.validation import resolve_stack
    if not resolve_stack(stack):
        return 1
    stack_dir = ROOT / "stacks" / stack

    _header(f"PLAN  {stack}")
    plan_rc = _plan(stack_dir)
    if plan_rc != 0:
        _write_audit(stack, plan_rc=plan_rc, apply_rc=None, checks=[])
        return 1

    if not args.yes:
        try:
            answer = input("\nApply this plan? [y/N] ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            return 2
        if answer != "y":
            print("Declined — no changes made.")
            return 2

    _header(f"APPLY  {stack}")
    apply_rc = _apply(stack_dir)
    if apply_rc != 0:
        _write_audit(stack, plan_rc=plan_rc, apply_rc=apply_rc, checks=[])
        return 1

    _header(f"CHECK  {stack}")
    from scripts.check import run as run_checks
    check_results = run_checks(stack)

    _write_audit(stack, plan_rc=plan_rc, apply_rc=apply_rc, checks=check_results)
    return 0 if all(r["status"] == "PASS" for r in check_results) else 1


def _plan(stack_dir: Path) -> int:
    plan_file = stack_dir / "tfplan"
    return subprocess.run(
        [_tf(), f"-chdir={stack_dir}", "plan", f"-out={plan_file}"],
        check=False,
    ).returncode


def _apply(stack_dir: Path) -> int:
    plan_file = stack_dir / "tfplan"
    return subprocess.run(
        [_tf(), f"-chdir={stack_dir}", "apply", str(plan_file)],
        check=False,
    ).returncode


def _write_audit(stack: str, plan_rc: int, apply_rc: int | None,
                 checks: list[dict]) -> None:
    AUDIT_FILE.parent.mkdir(exist_ok=True)
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "stack": stack,
        "plan_rc": plan_rc,
        "apply_rc": apply_rc,
        "checks": checks,
        "outcome": (
            "PASS"
            if apply_rc == 0 and all(c["status"] == "PASS" for c in checks)
            else "FAIL"
        ),
    }
    with AUDIT_FILE.open("a") as f:
        f.write(json.dumps(record) + "\n")
    print(f"\nAudit record → audit/runs.jsonl")


def _header(title: str) -> None:
    print(f"\n{'='*60}\n  {title}\n{'='*60}\n")


def _tf() -> str:
    return os.environ.get("TF_BIN", "terraform")


if __name__ == "__main__":
    sys.exit(main())
