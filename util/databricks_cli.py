"""
Small helpers for checks that call the Databricks CLI / SDK.

DATABRICKS_PROFILE (optional) selects a CLI profile; without it the CLI uses its default auth,
which in a pipeline is the Azure CLI session of the environment's Terraform identity.
"""
import json
import os
import subprocess


def _profile_args() -> list[str]:
    p = os.environ.get("DATABRICKS_PROFILE")
    return ["--profile", p] if p else []


def account_workspaces() -> list[dict] | None:
    r = subprocess.run(["databricks", "account", "workspaces", "list", *_profile_args(), "-o", "json"],
                       capture_output=True, text=True, timeout=60, check=False)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def workspace_by_name(name: str) -> dict | None:
    for w in account_workspaces() or []:
        if w.get("workspace_name") == name:
            return w
    return None


def workspace_url(name: str) -> str | None:
    w = workspace_by_name(name)
    return f"https://{w['deployment_name']}.azuredatabricks.net" if w and w.get("deployment_name") else None


def workspace_assignment_groups(workspace_id: str) -> set[str] | None:
    r = subprocess.run(["databricks", "account", "workspace-assignment", "list", str(workspace_id), *_profile_args(), "-o", "json"],
                       capture_output=True, text=True, timeout=60, check=False)
    if r.returncode != 0:
        return None
    try:
        return {a.get("principal", {}).get("group_name", "") for a in json.loads(r.stdout)}
    except json.JSONDecodeError:
        return None
