#!/usr/bin/env python3
"""
Plan one deployment target and show what it would change.

    python3 scripts/plan.py <stack> --scope <scope> [--env <env>] [--out FILE]

    python3 scripts/plan.py 40-unity-catalog --env dev --scope domain:claims
    python3 scripts/plan.py 20-identity --scope shared

The saved plan (default stacks/<stack>/<env>-<scope>.tfplan) is what apply.py applies, so what
you read here is exactly what is applied. The scope check then refuses a plan that would change
anything the target does not own.

Exit codes: 0 planned (and in scope); 1 target invalid or plan failed; 4 scope check failed.
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from util import tfrun  # noqa: E402
from util.scope import Target  # noqa: E402
from util.scope_check import check_plan  # noqa: E402
from util.targets import resolve  # noqa: E402


def has_changes(plan_json: dict) -> bool:
    return any((rc.get("change") or {}).get("actions") not in (["no-op"], ["read"])
               for rc in plan_json.get("resource_changes", []) or [] if rc.get("mode") == "managed")


def run(t: Target, naming: dict, out: Path | None = None, quiet: bool = False) -> tuple[int, Path, dict]:
    """Init, plan, save, scope-check. Returns (exit code, plan file, plan json)."""
    planfile = out or tfrun.plan_path(t)
    if tfrun.init(t) != 0:
        return 1, planfile, {}
    if tfrun.plan(t, planfile) != 0:
        return 1, planfile, {}
    plan_json = tfrun.show_json(t, planfile)
    Path(str(planfile) + ".json").write_text(json.dumps(plan_json))
    res = check_plan(plan_json, t, naming)
    if not quiet:
        print(f"\nScope check for {t.label()}: {res.checked} changed resources checked")
        for u in res.unattributed:
            print(f"  note: could not attribute {u}")
    if not res.ok:
        print("SCOPE CHECK FAILED: the plan changes things this target does not own:", file=sys.stderr)
        for v in res.violations:
            print(f"  - {v}", file=sys.stderr)
        return 4, planfile, plan_json
    return 0, planfile, plan_json


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("stack")
    ap.add_argument("--scope", required=True)
    ap.add_argument("--env")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    t, naming, problems = resolve(a.stack, a.env, a.scope)
    if problems:
        print("\n".join(f"ERROR: {p}" for p in problems), file=sys.stderr)
        return 1
    rc, planfile, _ = run(t, naming, a.out)
    if rc == 0:
        print(f"\nPlan saved: {planfile}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
