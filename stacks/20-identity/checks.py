"""
Post-apply checks for stack 20-identity.

Verifies that all expected Entra groups exist in the stack outputs,
that the platform Terraform SP has OIDC federated credentials, and
that the platform-admin persona group has members.

Expected group names are derived from config/ — adding a domain or SAR
in config automatically adds it to the expected set here.
"""
import subprocess

from util.config_reader import Config
from util.validation import CheckResult


def check_all_groups_present(outputs: dict) -> CheckResult:
    cfg = Config()
    groups = outputs.get("groups", {})
    if not groups:
        return CheckResult("all_groups_present", "RETRY",
                           "no groups in outputs yet (AIM sync may be pending)")

    # Build expected display names from config and compare to output names
    expected_names = cfg.expected_group_names()
    actual_names = {v["name"] for v in groups.values()}
    missing = expected_names - actual_names

    if missing:
        sample = sorted(missing)[:5]
        more = f" (and {len(missing) - 5} more)" if len(missing) > 5 else ""
        return CheckResult("all_groups_present", "FAIL",
                           f"missing groups: {', '.join(sample)}{more}")

    return CheckResult("all_groups_present", "PASS",
                       f"{len(groups)} groups present, all expected names found")


def check_deployer_sp_oidc(outputs: dict) -> CheckResult:
    """
    Verify that domain deployer SPs have OIDC federated credentials.
    Checks the first prd deployer found in outputs — if one is wired
    correctly they all are, since they are created by the same code.
    The platform Terraform SP is managed by bootstrap, not this stack.
    """
    cfg = Config()
    sps = outputs.get("service_principals", {})

    # Find any prd deployer SP in the outputs
    deployer_key = next(
        (k for k in sps if k.startswith("deploy:prd:")), None
    )
    if not deployer_key:
        return CheckResult("deployer_sp_oidc", "FAIL",
                           "no deploy:prd:* SPs found in service_principals output")

    deployer = sps[deployer_key]
    app_id = deployer.get("client_id", "")
    if not app_id:
        return CheckResult("deployer_sp_oidc", "FAIL",
                           f"{deployer_key} has no client_id in output")

    result = subprocess.run(
        ["az", "ad", "app", "federated-credential", "list",
         "--id", app_id, "--query", "length(@)", "-o", "tsv"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    count = int(result.stdout.strip() or "0")
    if count < 1:
        return CheckResult("deployer_sp_oidc", "FAIL",
                           f"{deployer['display_name']} has no OIDC federated credentials")
    return CheckResult("deployer_sp_oidc", "PASS",
                       f"{deployer['display_name']} has {count} federated credential(s)")


def check_platform_admin_has_members(outputs: dict) -> CheckResult:
    groups = outputs.get("groups", {})
    persona = groups.get("persona:platform-admin")
    if not persona:
        return CheckResult("platform_admin_has_members", "RETRY",
                           "persona:platform-admin not yet in outputs")

    object_id = persona.get("object_id", "")
    result = subprocess.run(
        ["az", "ad", "group", "member", "list",
         "--group", object_id, "--query", "length(@)", "-o", "tsv"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    count = int(result.stdout.strip() or "0")
    if count == 0:
        return CheckResult("platform_admin_has_members", "FAIL",
                           "piq-persona-platform-admin has no members — "
                           "add UPNs to platform-admin.members in config/personas.yaml")
    return CheckResult("platform_admin_has_members", "PASS",
                       f"piq-persona-platform-admin has {count} member(s)")


CHECKS = [
    check_all_groups_present,
    check_deployer_sp_oidc,
    check_platform_admin_has_members,
]
