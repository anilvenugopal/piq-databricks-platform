"""
Post-apply checks for stack 70-observability.

Verifies that all expected monitoring views are present in the stack
outputs. The expected set is fixed — these views are platform-defined
and do not vary with domain config.
"""
from util.validation import CheckResult

EXPECTED_VIEWS = {
    "prd_platform.audit.denied_requests",
    "prd_platform.audit.permission_changes",
    "prd_platform.governance.lineage_recent",
    "prd_platform.governance.pii_columns",
    "prd_platform.governance.products",
    "prd_platform.monitoring.cost_daily_by_env_domain",
    "prd_platform.monitoring.cost_untagged_usage",
    "prd_platform.observability.job_run_outcomes",
    "prd_platform.observability.query_activity_daily",
}


def check_observability_views(outputs: dict) -> CheckResult:
    views = outputs.get("views", [])
    if not views:
        return CheckResult("observability_views", "RETRY", "no views in outputs yet")

    actual = set(views)
    missing = EXPECTED_VIEWS - actual

    if missing:
        return CheckResult("observability_views", "FAIL",
                           f"missing views: {', '.join(sorted(missing))}")

    return CheckResult("observability_views", "PASS",
                       f"{len(actual)} observability views present")


CHECKS = [
    check_observability_views,
]
