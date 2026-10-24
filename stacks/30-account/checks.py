"""
Post-apply checks for stack 30-account (scopes shared, env, domain:<name>).

Verifies that the usage policies this scope owns exist, and that the groups it assigns to the
environment's workspace are really assigned in the Databricks account.
Expected values come from the naming module for this scope.
"""
from util.databricks_cli import workspace_assignment_groups, workspace_by_name
from util.validation import CheckResult, Context


def check_usage_policies(outputs: dict, ctx: Context) -> CheckResult:
    expected = set(ctx.naming["usage_scopes"])
    if not expected:
        return CheckResult("usage_policies", "PASS", f"this scope owns no usage policies ({ctx.target.sid})")
    policy_ids = outputs.get("usage_policy_ids", {})
    if not policy_ids:
        return CheckResult("usage_policies", "RETRY", "no usage_policy_ids in outputs yet")
    missing = expected - set(policy_ids)
    if missing:
        return CheckResult("usage_policies", "FAIL", f"missing usage policies: {', '.join(sorted(missing))}")
    return CheckResult("usage_policies", "PASS", f"{len(policy_ids)} usage policies present")


def check_workspace_assignments(outputs: dict, ctx: Context) -> CheckResult:
    """Groups this scope assigns to the environment's workspace appear in its assignment list."""
    wanted = {ctx.naming["all_group_names"][a["group"]] for a in ctx.naming["group_workspace_assignments"].values()}
    if not wanted:
        return CheckResult("workspace_assignments", "PASS", f"this scope assigns no groups ({ctx.target.sid})")

    ws = workspace_by_name(f"dbw-{ctx.prefix}-{ctx.env}")
    if ws is None:
        return CheckResult("workspace_assignments", "RETRY", f"dbw-{ctx.prefix}-{ctx.env} not found in the account (or the account API is not reachable)")
    assigned = workspace_assignment_groups(ws["workspace_id"])
    if assigned is None:
        return CheckResult("workspace_assignments", "RETRY", "could not list workspace assignments")
    missing = wanted - assigned
    if missing:
        sample = sorted(missing)[:5]
        return CheckResult("workspace_assignments", "RETRY",
                           f"groups not yet assigned to {ctx.env}: {', '.join(sample)} (AIM sync may be pending)")
    return CheckResult("workspace_assignments", "PASS", f"{len(wanted)} groups assigned to dbw-{ctx.prefix}-{ctx.env}")


CHECKS = [
    check_usage_policies,
    check_workspace_assignments,
]
