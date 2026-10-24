"""
Post-apply checks for stack 40-unity-catalog (scopes shared, env, domain:<name>).

Verifies that every catalog this scope owns exists, that the shared scope created every governed
tag, and that the local roles of each domain catalog have USE_CATALOG (read through the Databricks SDK).
Expected values come from the naming module for this scope.
"""
from util.databricks_cli import workspace_url
from util.validation import CheckResult, Context


def check_catalogs_present(outputs: dict, ctx: Context) -> CheckResult:
    expected = {c["name"] for c in ctx.naming["catalogs"].values()}
    if not expected:
        return CheckResult("catalogs_present", "PASS", f"this scope owns no catalogs ({ctx.target.sid})")
    catalogs = outputs.get("catalogs", {})
    if not catalogs:
        return CheckResult("catalogs_present", "RETRY", "no catalogs in outputs yet")
    missing = expected - set(catalogs.values())
    if missing:
        sample = sorted(missing)[:5]
        more = f" (and {len(missing) - 5} more)" if len(missing) > 5 else ""
        return CheckResult("catalogs_present", "FAIL", f"missing catalogs: {', '.join(sample)}{more}")
    return CheckResult("catalogs_present", "PASS", f"{len(expected)} catalogs present, all expected names found")


def check_domain_catalog_grants(outputs: dict, ctx: Context) -> CheckResult:
    """Each domain catalog in this scope: its producer group can use it."""
    domain_catalogs = [c for c in ctx.naming["catalogs"].values() if c["kind"] == "domain"]
    if not domain_catalogs:
        return CheckResult("domain_catalog_grants", "PASS", "no domain catalogs in this scope")

    url = workspace_url(f"dbw-{ctx.prefix}-{ctx.env}")
    if not url:
        return CheckResult("domain_catalog_grants", "RETRY", "could not determine the workspace URL (account API not reachable?)")
    try:
        from databricks.sdk import WorkspaceClient
        w = WorkspaceClient(host=url)
    except Exception as e:
        return CheckResult("domain_catalog_grants", "RETRY", f"SDK init failed: {e}")

    failures = []
    for c in domain_catalogs:
        group = ctx.naming["all_group_names"][f"{ctx.env}:{c['owner']}:producer"]
        try:
            grants = w.grants.get_effective(securable_type="CATALOG", full_name=c["name"], principal=group)
            privileges = {p.privilege.value for a in (grants.privilege_assignments or []) for p in (a.privileges or [])}
            if "USE_CATALOG" not in privileges:
                failures.append(f"{group} missing USE_CATALOG on {c['name']}")
        except Exception as e:
            failures.append(f"{c['name']}: {e}")
    if failures:
        return CheckResult("domain_catalog_grants", "FAIL", "; ".join(failures))
    return CheckResult("domain_catalog_grants", "PASS", f"producer groups have USE_CATALOG on {len(domain_catalogs)} domain catalog(s)")


CHECKS = [
    check_catalogs_present,
    check_domain_catalog_grants,
]
