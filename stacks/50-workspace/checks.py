"""
Post-apply checks for stack 50-workspace.

Verifies that all expected SQL warehouses exist in both workspaces and
that the system catalog USE_CATALOG grant is in place for the monitoring
group in prd. Warehouse names are derived from config/.
"""
import json
import subprocess

from util.config_reader import Config
from util.validation import CheckResult


def _prd_workspace_url(cfg: Config) -> str | None:
    result = subprocess.run(
        ["databricks", "account", "workspaces", "list",
         "--profile", "premiumIQ", "-o", "json"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if result.returncode != 0:
        return None
    try:
        workspaces = json.loads(result.stdout)
        prd = next(
            (w for w in workspaces
             if w.get("workspace_name") == f"dbw-{cfg.prefix}-prd"), None
        )
        if prd:
            return f"https://{prd['deployment_name']}.azuredatabricks.net"
    except (json.JSONDecodeError, KeyError):
        pass
    return None


def check_warehouses_exist(outputs: dict) -> CheckResult:
    cfg = Config()
    warehouse_ids = outputs.get("warehouse_ids", {})
    if not warehouse_ids:
        return CheckResult("warehouses_exist", "RETRY",
                           "no warehouse_ids in outputs yet")

    expected = cfg.expected_warehouse_names()  # env -> set of names
    failures = []

    for env, expected_names in expected.items():
        actual_names = set(warehouse_ids.get(env, {}).keys())
        missing = expected_names - actual_names
        if missing:
            failures.append(f"{env}: missing {', '.join(sorted(missing))}")

    if failures:
        return CheckResult("warehouses_exist", "FAIL", "; ".join(failures))

    total = sum(len(v) for v in warehouse_ids.values())
    return CheckResult("warehouses_exist", "PASS",
                       f"{total} warehouses present across all environments")


def check_system_catalog_grant(outputs: dict) -> CheckResult:
    """
    Verify that the platform-monitoring group has USE_CATALOG on the
    system catalog in the prd workspace.
    """
    cfg = Config()
    monitoring_group = f"{cfg.prefix}-platform-monitoring"

    ws_url = _prd_workspace_url(cfg)
    if not ws_url:
        return CheckResult("system_catalog_grant", "RETRY",
                           "could not determine prd workspace URL")

    try:
        from databricks.sdk import WorkspaceClient
        w = WorkspaceClient(host=ws_url)
        grants = w.grants.get_effective(
            securable_type="CATALOG",
            full_name="system",
            principal=monitoring_group,
        )
        privileges = {
            p.privilege.value
            for a in (grants.privilege_assignments or [])
            for p in (a.privileges or [])
        }
        if "USE_CATALOG" not in privileges:
            return CheckResult("system_catalog_grant", "FAIL",
                               f"{monitoring_group} does not have USE_CATALOG on system catalog")
    except Exception as e:
        return CheckResult("system_catalog_grant", "RETRY",
                           f"could not check system catalog grants: {e}")

    return CheckResult("system_catalog_grant", "PASS",
                       f"{monitoring_group} has USE_CATALOG on system catalog")


CHECKS = [
    check_warehouses_exist,
    check_system_catalog_grant,
]
