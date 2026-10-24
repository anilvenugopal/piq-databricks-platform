"""
Post-apply checks for stack 50-workspace (scopes env, domain:<name>).

Verifies that every SQL warehouse this scope owns exists, and (env scope of the prod environment)
that the monitoring group can use the system catalog. Warehouse names come from the naming module.
"""
from util.databricks_cli import workspace_url
from util.validation import CheckResult, Context


def check_warehouses_exist(outputs: dict, ctx: Context) -> CheckResult:
    expected = set(ctx.naming["warehouses"].get(ctx.env, {}))
    if not expected:
        return CheckResult("warehouses_exist", "PASS", f"this scope owns no warehouses ({ctx.target.sid})")
    warehouse_ids = outputs.get("warehouse_ids", {})
    if not warehouse_ids:
        return CheckResult("warehouses_exist", "RETRY", "no warehouse_ids in outputs yet")
    missing = expected - set(warehouse_ids)
    if missing:
        return CheckResult("warehouses_exist", "FAIL", f"missing warehouses: {', '.join(sorted(missing))}")
    return CheckResult("warehouses_exist", "PASS", f"{len(warehouse_ids)} warehouses present in {ctx.env}")


def check_system_catalog_grant(outputs: dict, ctx: Context) -> CheckResult:
    """The platform-monitoring group has USE_CATALOG on the system catalog (prod env scope only)."""
    if ctx.scope != "env" or ctx.env != ctx.naming["prod_env"]:
        return CheckResult("system_catalog_grant", "PASS", "system-table grants are only made by the prod environment's env scope")
    group = ctx.naming["platform_group_names"]["platform-monitoring"]
    url = workspace_url(f"dbw-{ctx.prefix}-{ctx.env}")
    if not url:
        return CheckResult("system_catalog_grant", "RETRY", "could not determine the workspace URL")
    try:
        from databricks.sdk import WorkspaceClient
        w = WorkspaceClient(host=url)
        grants = w.grants.get_effective(securable_type="CATALOG", full_name="system", principal=group)
        privileges = {p.privilege.value for a in (grants.privilege_assignments or []) for p in (a.privileges or [])}
        if "USE_CATALOG" not in privileges:
            return CheckResult("system_catalog_grant", "FAIL", f"{group} does not have USE_CATALOG on the system catalog")
    except Exception as e:
        return CheckResult("system_catalog_grant", "RETRY", f"could not check system catalog grants: {e}")
    return CheckResult("system_catalog_grant", "PASS", f"{group} has USE_CATALOG on the system catalog")


CHECKS = [
    check_warehouses_exist,
    check_system_catalog_grant,
]
