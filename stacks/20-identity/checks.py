"""
Post-apply checks for stack 20-identity (scopes shared, env, domain:<name>).

Verifies that the groups this scope owns exist in the stack outputs, and that the service principals
it owns carry GitHub OIDC federated credentials. Expected names come from the naming module for this
scope, so adding a domain or a persona extends the expected set automatically.

Who is IN the groups is not checked here: that is stack 25 (entitlements).
"""
import subprocess

from util.validation import CheckResult, Context


def check_all_groups_present(outputs: dict, ctx: Context) -> CheckResult:
    expected = {g["name"] for g in ctx.naming["groups"].values()}
    if not expected:
        return CheckResult("all_groups_present", "PASS", f"this scope owns no groups ({ctx.target.sid})")
    groups = outputs.get("groups", {})
    if not groups:
        return CheckResult("all_groups_present", "RETRY", "no groups in outputs yet (AIM sync may be pending)")

    missing = expected - {v["name"] for v in groups.values()}
    if missing:
        sample = sorted(missing)[:5]
        more = f" (and {len(missing) - 5} more)" if len(missing) > 5 else ""
        return CheckResult("all_groups_present", "FAIL", f"missing groups: {', '.join(sample)}{more}")
    return CheckResult("all_groups_present", "PASS", f"{len(groups)} groups present, all expected names found")


def check_deployer_sp_oidc(outputs: dict, ctx: Context) -> CheckResult:
    """Service principals with GitHub subjects must have OIDC federated credentials."""
    expected = {k: s for k, s in ctx.naming["service_principals"].items() if s["github_subjects"]}
    if not expected:
        return CheckResult("deployer_sp_oidc", "PASS", "no service principals with GitHub trust in this scope")
    sps = outputs.get("service_principals", {})

    failures = []
    for key, s in expected.items():
        out = sps.get(key)
        if not out or not out.get("client_id"):
            failures.append(f"{s['display_name']}: not in outputs")
            continue
        result = subprocess.run(
            ["az", "ad", "app", "federated-credential", "list", "--id", out["client_id"], "--query", "length(@)", "-o", "tsv"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        if int(result.stdout.strip() or "0") < len(s["github_subjects"]):
            failures.append(f"{s['display_name']}: fewer federated credentials than trusted subjects")
    if failures:
        return CheckResult("deployer_sp_oidc", "FAIL", "; ".join(failures))
    return CheckResult("deployer_sp_oidc", "PASS", f"{len(expected)} service principals have their OIDC credentials")


CHECKS = [
    check_all_groups_present,
    check_deployer_sp_oidc,
]
