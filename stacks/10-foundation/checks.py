"""
Post-apply checks for stack 10-foundation (scope env).

Verifies that the environment's Databricks workspace is named as expected and reachable, and that its
Azure storage account is provisioned.
"""
import subprocess
import urllib.error
import urllib.request

from util.validation import CheckResult, Context


def check_workspaces_reachable(outputs: dict, ctx: Context) -> CheckResult:
    workspaces = outputs.get("workspaces", {})
    if not workspaces:
        return CheckResult("workspaces_reachable", "RETRY", "no workspace outputs yet")

    expected = f"dbw-{ctx.prefix}-{ctx.env}"
    failures = []
    for env, ws in workspaces.items():
        if expected not in ws.get("resource_id", ""):
            failures.append(f"{env}: expected '{expected}' in resource_id, got '{ws.get('resource_id', '')}'")
            continue
        url = ws.get("url", "")
        if not url:
            failures.append(f"{env}: missing url in outputs")
            continue
        try:
            urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=10)
        except urllib.error.HTTPError as e:
            if e.code < 500:
                continue  # any non-5xx means the workspace is serving traffic
            failures.append(f"{env} ({url}): HTTP {e.code}")
        except Exception as e:
            failures.append(f"{env}: {e}")

    if failures:
        return CheckResult("workspaces_reachable", "FAIL", "; ".join(failures))
    return CheckResult("workspaces_reachable", "PASS", f"reachable: {', '.join(workspaces)}")


def check_storage_accounts(outputs: dict, ctx: Context) -> CheckResult:
    storage = outputs.get("storage", {})
    if not storage:
        return CheckResult("storage_accounts", "RETRY", "no storage outputs yet")

    failures = []
    for env, info in storage.items():
        # The dfs_endpoint looks like: https://stpiqdevlakeXXX.dfs.core.windows.net/
        endpoint = info.get("dfs_endpoint", "")
        name = endpoint.replace("https://", "").split(".")[0] if endpoint else ""
        if not name:
            failures.append(f"{env}: cannot determine storage account name")
            continue
        result = subprocess.run(
            ["az", "storage", "account", "show", "--name", name, "--query", "provisioningState", "-o", "tsv"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        state = result.stdout.strip()
        if state != "Succeeded":
            failures.append(f"{env} ({name}): provisioningState={state or 'not found'}")

    if failures:
        return CheckResult("storage_accounts", "FAIL", "; ".join(failures))
    return CheckResult("storage_accounts", "PASS", f"storage accounts provisioned for: {', '.join(storage)}")


CHECKS = [
    check_workspaces_reachable,
    check_storage_accounts,
]
