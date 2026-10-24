#!/usr/bin/env python3
"""
Plan, confirm, apply, check and record ONE deployment target.

    python3 scripts/apply.py <stack> --scope <scope> [--env <env>]                 # interactive
    python3 scripts/apply.py <stack> --scope <scope> --env <env> --plan FILE --yes # CI: a reviewed plan

    python3 scripts/apply.py 40-unity-catalog --env dev --scope domain:claims
    python3 scripts/apply.py 40-unity-catalog --env prd --scope domain:claims --release rel-2026.10.23.1
    python3 scripts/apply.py 20-identity --scope shared

What it does, in order:
  1. resolves the target (stack, environment, scope) and refuses an invalid one
  2. works out the release: the tag at HEAD, or sha:<commit> for environments that accept any commit.
     An environment with promotes_from only accepts a release tag, and HEAD must BE that tag's commit
     with a clean tree
  3. promotion gate: the release must already have been deployed successfully to every environment
     in promotes_from (--hotfix --approver NAME skips that where the environment allows hotfixes)
  4. plans (or takes --plan FILE), shows the plan, runs the scope check
  5. asks for confirmation (--yes skips it, but ONLY together with --plan: CI applies a plan that a
     person already read, never a fresh one)
  6. applies the saved plan, runs the stack's checks, writes the deploy record

An empty plan still counts as a successful deploy of the release: a release that does not touch a domain
must still be promotable for it.

Exit codes:
  0  applied (or nothing to apply) and all checks passed
  1  target invalid, plan or apply failed, or checks failed
  2  declined at the prompt, or --yes without --plan
  4  scope check failed
  5  promotion gate refused
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

AUDIT_FILE = ROOT / "audit" / "runs.jsonl"

from scripts import plan as plan_mod  # noqa: E402
from util import deploys, release, tfrun  # noqa: E402
from util.scope import Target  # noqa: E402
from util.scope_check import check_plan  # noqa: E402
from util.targets import context, resolve  # noqa: E402


def _header(title: str) -> None:
    print(f"\n{'=' * 60}\n  {title}\n{'=' * 60}\n")


def _release_for(t: Target, env_cfg: dict, wanted: str | None) -> tuple[str, str, list[str]]:
    """(release name, sha, problems). Environments with promotes_from need a clean tagged HEAD."""
    sha = release.head_sha()
    needs_tag = bool((env_cfg.get(t.env or "", {}) or {}).get("promotes_from"))
    rel = wanted or release.describe_head()
    problems = []
    if wanted:
        if not release.is_release_tag(wanted):
            problems.append(f"--release must look like rel-YYYY.MM.DD.N (got {wanted})")
        else:
            try:
                if release.tag_sha(wanted) != sha:
                    problems.append(f"HEAD is not {wanted}: check out the tag (git checkout {wanted}) so the code that runs is the code that was released")
            except RuntimeError as e:
                problems.append(str(e))
    if needs_tag and not release.is_release_tag(rel):
        problems.append(f"environment {t.env} only accepts a release tag; HEAD has none (cut one with scripts/release.py)")
    if (needs_tag or wanted) and not release.is_clean():
        problems.append("the working tree has uncommitted changes; deploy a clean checkout of the release")
    return rel, sha, problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("stack")
    ap.add_argument("--scope", required=True, help="shared | env | access | domain:<name>")
    ap.add_argument("--env", help="environment (not used for scope shared)")
    ap.add_argument("--plan", type=Path, help="apply this saved plan instead of planning")
    ap.add_argument("--yes", "-y", action="store_true", help="skip the prompt; requires --plan (for CI)")
    ap.add_argument("--release", help="release tag being deployed (HEAD must be that tag)")
    ap.add_argument("--hotfix", action="store_true", help="skip the promotion gate (environment must allow hotfixes)")
    ap.add_argument("--approver", default="", help="who approved the hotfix")
    ap.add_argument("--no-record", action="store_true", help="do not write a deploy record (local experiments)")
    a = ap.parse_args()

    if a.yes and not a.plan:
        print("ERROR: --yes needs --plan. A pipeline applies a plan that a person already reviewed, never a new one.", file=sys.stderr)
        return 2

    t, naming, problems = resolve(a.stack, a.env, a.scope)
    if problems:
        print("\n".join(f"ERROR: {p}" for p in problems), file=sys.stderr)
        return 1
    env_cfg = naming["environments"]

    rel, sha, problems = _release_for(t, env_cfg, a.release)
    if problems:
        print("\n".join(f"ERROR: {p}" for p in problems), file=sys.stderr)
        return 1

    st = None if a.no_record else deploys.store(naming["platform"])
    if st is not None:
        gate = deploys.check_promotion(st, t, rel, env_cfg, hotfix=a.hotfix, approver=a.approver)
        if gate:
            print(f"PROMOTION GATE REFUSED {rel} for {t.label()}:", file=sys.stderr)
            print("\n".join(f"  - {g}" for g in gate), file=sys.stderr)
            return 5

    _header(f"PLAN  {t.label()}  ({rel})")
    if a.plan:
        planfile = a.plan
        if tfrun.init(t) != 0:
            return 1
        plan_json = tfrun.show_json(t, planfile)
        print(tfrun.show_text(t, planfile))
        res = check_plan(plan_json, t, naming)
        if not res.ok:
            print("SCOPE CHECK FAILED:\n" + "\n".join(f"  - {v}" for v in res.violations), file=sys.stderr)
            return 4
    else:
        rc, planfile, plan_json = plan_mod.run(t, naming)
        if rc != 0:
            _audit(t, rel, plan_rc=rc, apply_rc=None, checks=[])
            return rc

    changes = plan_mod.has_changes(plan_json)
    if changes and not a.yes:
        try:
            answer = input("\nApply this plan? [y/N] ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            return 2
        if answer != "y":
            print("Declined: no changes made.")
            return 2

    apply_rc = 0
    if changes:
        _header(f"APPLY  {t.label()}")
        apply_rc = tfrun.apply(t, planfile)
    else:
        print("No changes to apply; recording the release as deployed.")
    if apply_rc != 0:
        _audit(t, rel, plan_rc=0, apply_rc=apply_rc, checks=[])
        if st is not None:
            st.put(deploys.record(t, rel, sha, "FAIL", hotfix=a.hotfix, approver=a.approver))
        return 1

    _header(f"CHECK  {t.label()}")
    from scripts.check import run as run_checks
    results = run_checks(t, context(t, naming))
    passed = all(r["status"] == "PASS" for r in results)

    _audit(t, rel, plan_rc=0, apply_rc=apply_rc, checks=results)
    if st is not None:
        where = st.put(deploys.record(t, rel, sha, "PASS" if passed else "FAIL", hotfix=a.hotfix, approver=a.approver, checks=results))
        print(f"\nDeploy record: {where}")
    if a.hotfix:
        print("\nHOTFIX: replay this release through the environments it skipped, and merge the fix to main.")
    return 0 if passed else 1


def _audit(t: Target, rel: str, plan_rc: int, apply_rc: int | None, checks: list[dict]) -> None:
    AUDIT_FILE.parent.mkdir(exist_ok=True)
    rec = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "stack": t.stack, "env": t.env, "scope": t.scope, "release": rel,
        "plan_rc": plan_rc, "apply_rc": apply_rc, "checks": checks,
        "outcome": "PASS" if apply_rc == 0 and all(c["status"] == "PASS" for c in checks) else "FAIL",
        "actor": os.environ.get("GITHUB_ACTOR") or os.environ.get("USER", "unknown"),
    }
    with AUDIT_FILE.open("a") as f:
        f.write(json.dumps(rec) + "\n")
    print(f"\nAudit record: audit/runs.jsonl")


if __name__ == "__main__":
    sys.exit(main())
