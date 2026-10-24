"""
Post-apply checks for stack 25-access (scope access).

Verifies that every membership and approval the entitlements ask for was applied: the counts in the
stack outputs match what the naming module derived from config/entitlements/<env>/.
"""
from util.validation import CheckResult, Context


def check_memberships_applied(outputs: dict, ctx: Context) -> CheckResult:
    got = outputs.get("memberships")
    if got is None:
        return CheckResult("memberships_applied", "RETRY", "no memberships output yet")
    want = {
        "nesting": len(ctx.naming["access_nesting"]),
        "users": len(ctx.naming["access_user_memberships"]),
        "test": len(ctx.naming["access_test_user_memberships"]),
    }
    if got != want:
        return CheckResult("memberships_applied", "FAIL", f"applied {got}, entitlements ask for {want}")
    return CheckResult("memberships_applied", "PASS",
                       f"{want['users']} memberships, {want['nesting']} approvals, {want['test']} test-user memberships in {ctx.env}")


CHECKS = [
    check_memberships_applied,
]
