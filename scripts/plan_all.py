#!/usr/bin/env python3
"""
Plan every target of an environment (read-only) and report which ones have changes.

    python3 scripts/plan_all.py --env dev                       # every stack, every scope
    python3 scripts/plan_all.py --env prd --stack 40-unity-catalog --scope domain:claims
    python3 scripts/plan_all.py --env dev --markdown report.md  # also write a table for a PR comment
    python3 scripts/plan_all.py --env dev --include-shared      # also the shared scope (no environment)

Use it to see what a merge would change, and (nightly, plan only) to find drift: a target with changes
that nobody merged was changed by hand. It never applies anything.

Exit codes: 0 nothing to change anywhere; 2 at least one target has changes; 1 a plan failed or a plan
was refused by the scope check.
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts import plan as plan_mod  # noqa: E402
from util.targets import all_targets, naming_all, stack_order  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--stack", action="append", help="limit to these stacks (repeatable)")
    ap.add_argument("--scope", action="append", help="limit to these scopes (repeatable)")
    ap.add_argument("--include-shared", action="store_true")
    ap.add_argument("--markdown", type=Path)
    a = ap.parse_args()

    naming = naming_all()
    if a.env not in naming["env_keys"]:
        print(f"ERROR: unknown environment '{a.env}' (known: {', '.join(naming['env_keys'])})", file=sys.stderr)
        return 1
    targets = all_targets(naming, a.stack, a.env)
    if a.include_shared:
        targets += [t for t in all_targets(naming, a.stack) if t.scope == "shared"]
    if a.scope:
        targets = [t for t in targets if t.scope in a.scope]
    targets.sort(key=lambda t: (stack_order(t.stack), t.scope != "shared", t.scope != "env", t.scope))

    rows, worst = [], 0
    for t in targets:
        print(f"\n##### {t.label()}")
        rc, planfile, plan_json = plan_mod.run(t, naming, quiet=True)
        if rc != 0:
            rows.append((t, "FAILED" if rc == 1 else "SCOPE CHECK FAILED", 0))
            worst = 1
            continue
        n = sum(1 for rc_ in plan_json.get("resource_changes", []) or []
                if rc_.get("mode") == "managed" and (rc_.get("change") or {}).get("actions") not in (["no-op"], ["read"]))
        rows.append((t, "changes" if n else "no changes", n))
        if n and worst == 0:
            worst = 2

    lines = ["| stack | scope | result | changed resources |", "|---|---|---|---|"]
    lines += [f"| {t.stack} | {t.scope} | {res} | {n} |" for t, res, n in rows]
    report = "\n".join(lines)
    print("\n" + report)
    if a.markdown:
        a.markdown.write_text(report + "\n")
    return worst


if __name__ == "__main__":
    sys.exit(main())
