"""
Post-apply checks for stack 30-account.

Verifies that serverless usage policies exist for every expected
env:domain combination, and that key groups are assigned to the
correct workspaces in the Databricks account.

Expected policy keys are derived from config/ — adding a domain
automatically adds it to the expected set.
"""
import subprocess
import json

from util.config_reader import Config
from util.validation import CheckResult


def check_usage_policies(outputs: dict) -> CheckResult:
    cfg = Config()
    policy_ids = outputs.get("usage_policy_ids", {})
    if not policy_ids:
        return CheckResult("usage_policies", "RETRY",
                           "no usage_policy_ids in outputs yet")

    # Expected keys: env:domain for every domain + vault + platform + sandbox,
    # plus consumer keys (prd only).
    expected: set[str] = set()
    for env in cfg.envs:
        for domain in cfg.domains:
            expected.add(f"{env}:{domain}")
        expected.add(f"{env}:vault")
        expected.add(f"{env}:platform")
        expected.add(f"{env}:sandbox")
    for ck in cfg.consumer_keys:
        expected.add(f"prd:{ck}")

    missing = expected - set(policy_ids.keys())
    if missing:
        return CheckResult("usage_policies", "FAIL",
                           f"missing usage policies: {', '.join(sorted(missing))}")

    return CheckResult("usage_policies", "PASS",
                       f"{len(policy_ids)} usage policies present")


def check_workspace_assignments(outputs: dict) -> CheckResult:
    """
    Verify groups are assigned to workspaces via the Databricks account CLI.
    Checks that piq-metastore-admins and piq-prd-workspace-admins appear
    in the prd workspace assignment list.
    """
    cfg = Config()
    p = cfg.prefix

    # Get prd workspace ID from foundation outputs via remote state — not available
    # directly in stack 30 outputs, so we call the Databricks account API.
    result = subprocess.run(
        ["databricks", "account", "workspaces", "list", "--profile", "premiumIQ",
         "-o", "json"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if result.returncode != 0:
        return CheckResult("workspace_assignments", "RETRY",
                           "could not list workspaces from Databricks account API")

    try:
        workspaces = json.loads(result.stdout)
    except json.JSONDecodeError:
        return CheckResult("workspace_assignments", "RETRY",
                           "unexpected response from Databricks account API")

    prd_ws = next(
        (w for w in workspaces if w.get("workspace_name") == f"dbw-{p}-prd"), None
    )
    if not prd_ws:
        return CheckResult("workspace_assignments", "FAIL",
                           f"dbw-{p}-prd not found in account workspace list")

    ws_id = str(prd_ws["workspace_id"])
    assign_result = subprocess.run(
        ["databricks", "account", "workspace-assignment", "list", ws_id,
         "--profile", "premiumIQ", "-o", "json"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if assign_result.returncode != 0:
        return CheckResult("workspace_assignments", "RETRY",
                           "could not list workspace assignments")

    try:
        assignments = json.loads(assign_result.stdout)
    except json.JSONDecodeError:
        return CheckResult("workspace_assignments", "RETRY",
                           "unexpected response from workspace assignment API")

    assigned_names = {
        a.get("principal", {}).get("group_name", "")
        for a in assignments
    }

    required = {f"{p}-metastore-admins", f"{p}-prd-workspace-admins"}
    missing = required - assigned_names
    if missing:
        return CheckResult("workspace_assignments", "RETRY",
                           f"groups not yet assigned to prd workspace: "
                           f"{', '.join(sorted(missing))} (AIM sync may be pending)")

    return CheckResult("workspace_assignments", "PASS",
                       f"required groups assigned to dbw-{p}-prd")


CHECKS = [
    check_usage_policies,
    check_workspace_assignments,
]
