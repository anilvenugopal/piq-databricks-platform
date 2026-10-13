#!/usr/bin/env python3
"""
Access-portal integration: turn an approved request into a config change.

The portal (Entra SSO front end -> GitHub Issue -> admin applies the `approved`
label) calls this from .github/workflows/provision-access.yml. Instead of running
CREATE USER / GRANT statements, it edits YAML; the workflow opens a PR; merging
and applying stack 20 (and 40 for sandboxes) makes it real. Entra group
membership flows into Databricks automatically.

    python3 scripts/provision_access.py --upn jane@corp.com \
        --persona data-analyst --sandbox --issue 12

Deprovisioning: --remove with the same arguments.
"""
import argparse
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(name):
    return yaml.safe_load((ROOT / "config" / name).read_text()) or {}


def dump(name, data, header):
    text = yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
    (ROOT / "config" / name).write_text(header + text)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--upn", required=True)
    ap.add_argument("--persona")
    ap.add_argument("--sandbox", action="store_true")
    ap.add_argument("--issue", default="")
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()
    changed = []

    if a.persona:
        p = load("personas.yaml")
        if a.persona not in p["personas"]:
            print(f"unknown persona {a.persona}", file=sys.stderr)
            return 2
        members = p["personas"][a.persona].setdefault("members", []) or []
        if a.remove and a.upn in members:
            members.remove(a.upn)
            changed.append(f"removed from persona {a.persona}")
        elif not a.remove and a.upn not in members:
            members.append(a.upn)
            changed.append(f"added to persona {a.persona}")
        p["personas"][a.persona]["members"] = sorted(members)
        dump("personas.yaml", p, "# Edited by scripts/provision_access.py - see git history for who/why.\n")

    if a.sandbox:
        s = load("sandbox_users.yaml")
        users = s.get("users") or []
        present = [u for u in users if u["upn"] == a.upn]
        if a.remove and present:
            users = [u for u in users if u["upn"] != a.upn]
            changed.append("sandbox schema removed")
        elif not a.remove and not present:
            users.append({"upn": a.upn, "requested_via": f"issue #{a.issue}" if a.issue else "manual"})
            changed.append("sandbox schema added")
        dump("sandbox_users.yaml", {"users": users}, "# Personal dev sandboxes. Edited via the access portal flow.\n")

    print("; ".join(changed) if changed else "no change")
    return 0


if __name__ == "__main__":
    sys.exit(main())
