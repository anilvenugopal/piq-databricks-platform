"""
Post-apply checks for stack 40-unity-catalog.

Verifies that all expected catalogs exist in the stack outputs and
that key grants are in place using the Databricks SDK.

Expected catalog names are derived from config/ — adding a domain
automatically extends the expected set.
"""
from util.config_reader import Config
from util.validation import CheckResult


def check_catalogs_present(outputs: dict) -> CheckResult:
    cfg = Config()
    catalogs = outputs.get("catalogs", {})
    if not catalogs:
        return CheckResult("catalogs_present", "RETRY",
                           "no catalogs in outputs yet")

    # outputs maps key -> catalog_name string
    actual_names = set(catalogs.values())
    expected_names = cfg.expected_catalog_names()
    missing = expected_names - actual_names

    if missing:
        sample = sorted(missing)[:5]
        more = f" (and {len(missing) - 5} more)" if len(missing) > 5 else ""
        return CheckResult("catalogs_present", "FAIL",
                           f"missing catalogs: {', '.join(sample)}{more}")

    return CheckResult("catalogs_present", "PASS",
                       f"{len(actual_names)} catalogs present, all expected names found")


def check_domain_catalog_grants(outputs: dict) -> CheckResult:
    """
    Verify that producer groups have USE_CATALOG on domain catalogs
    using the Databricks SDK against the prd workspace.
    """
    cfg = Config()
    from databricks.sdk import WorkspaceClient
    import subprocess, json

    # Get prd workspace URL from foundation stack output
    result = subprocess.run(
        ["databricks", "account", "workspaces", "list",
         "--profile", "premiumIQ", "-o", "json"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if result.returncode != 0:
        return CheckResult("domain_catalog_grants", "RETRY",
                           "could not reach Databricks account API")

    workspaces = json.loads(result.stdout)
    prd_ws = next(
        (w for w in workspaces
         if w.get("workspace_name") == f"dbw-{cfg.prefix}-prd"), None
    )
    if not prd_ws:
        return CheckResult("domain_catalog_grants", "FAIL",
                           f"dbw-{cfg.prefix}-prd not found in workspace list")

    host = prd_ws.get("deployment_name", "")
    if not host:
        return CheckResult("domain_catalog_grants", "FAIL",
                           "prd workspace has no deployment_name")

    ws_url = f"https://{host}.azuredatabricks.net"
    try:
        w = WorkspaceClient(host=ws_url)
    except Exception as e:
        return CheckResult("domain_catalog_grants", "RETRY", f"SDK init failed: {e}")

    failures = []
    for domain in cfg.domains:
        catalog_name = f"prd_{domain}"
        producer_group = f"{cfg.prefix}-prd-{domain.replace('_', '-')}-producer"
        try:
            grants = w.grants.get_effective(
                securable_type="CATALOG", full_name=catalog_name,
                principal=producer_group,
            )
            privileges = {
                p.privilege.value
                for a in (grants.privilege_assignments or [])
                for p in (a.privileges or [])
            }
            if "USE_CATALOG" not in privileges:
                failures.append(
                    f"{producer_group} missing USE_CATALOG on {catalog_name}"
                )
        except Exception as e:
            failures.append(f"{catalog_name}: {e}")

    if failures:
        return CheckResult("domain_catalog_grants", "FAIL", "; ".join(failures))
    return CheckResult("domain_catalog_grants", "PASS",
                       f"producer groups have USE_CATALOG on all {len(cfg.domains)} domain catalogs")


CHECKS = [
    check_catalogs_present,
    check_domain_catalog_grants,
]
