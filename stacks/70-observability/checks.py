"""
Post-apply checks for stack 70-observability (scope env, prod environment only).

Verifies that all expected monitoring views are present in the stack outputs. The expected set is
fixed: these views are platform-defined and do not vary with domain config.
"""
from util.validation import CheckResult, Context

EXPECTED_VIEWS = {
    "audit.denied_requests",
    "audit.permission_changes",
    "governance.lineage_recent",
    "governance.pii_columns",
    "governance.products",
    "monitoring.cost_daily_by_env_domain",
    "monitoring.cost_untagged_usage",
    "observability.job_run_outcomes",
    "observability.query_activity_daily",
}


def check_observability_views(outputs: dict, ctx: Context) -> CheckResult:
    views = outputs.get("views", [])
    if not views:
        return CheckResult("observability_views", "RETRY", "no views in outputs yet")
    expected = {f"{ctx.env}_platform.{v}" for v in EXPECTED_VIEWS}
    missing = expected - set(views)
    if missing:
        return CheckResult("observability_views", "FAIL", f"missing views: {', '.join(sorted(missing))}")
    return CheckResult("observability_views", "PASS", f"{len(views)} observability views present")


CHECKS = [
    check_observability_views,
]
