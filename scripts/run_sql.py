#!/usr/bin/env python3
"""
Run a SQL file on a SQL warehouse through the Statement Execution API.

Used by Terraform (terraform_data local-exec) for objects that have no native
Terraform resource: masking functions and platform views.

    python3 scripts/run_sql.py --host https://adb-123.azuredatabricks.net \
        --warehouse-id abc123 --file sql/governance/masking_functions.sql \
        --set catalog=dev_platform

Auth: DATABRICKS_AUTH_TYPE defaults to azure-cli (the active `az login`).
Statements are split on semicolons at line ends; ${name} placeholders are
replaced from --set name=value pairs.
"""
import argparse
import os
import re
import string
import sys
import time

from databricks.sdk import WorkspaceClient
from databricks.sdk.service.sql import StatementState


def statements(text: str):
    # Drop full-line comments, then split on ';' at end of line.
    lines = [ln for ln in text.splitlines() if not ln.strip().startswith("--")]
    for stmt in re.split(r";\s*$", "\n".join(lines), flags=re.MULTILINE):
        if stmt.strip():
            yield stmt.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--warehouse-id", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--set", action="append", default=[], help="name=value substitution")
    args = ap.parse_args()

    subs = dict(s.split("=", 1) for s in args.set)
    sql = string.Template(open(args.file, encoding="utf-8").read()).substitute(subs)

    os.environ.setdefault("DATABRICKS_AUTH_TYPE", "azure-cli")
    w = WorkspaceClient(host=args.host)

    for i, stmt in enumerate(statements(sql), 1):
        first_line = stmt.splitlines()[0][:100]
        print(f"[{i}] {first_line}")
        resp = w.statement_execution.execute_statement(
            statement=stmt, warehouse_id=args.warehouse_id, wait_timeout="50s"
        )
        while resp.status.state in (StatementState.PENDING, StatementState.RUNNING):
            time.sleep(3)
            resp = w.statement_execution.get_statement(resp.statement_id)
        if resp.status.state != StatementState.SUCCEEDED:
            err = resp.status.error.message if resp.status.error else resp.status.state
            print(f"    FAILED: {err}", file=sys.stderr)
            return 1
        print("    ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
