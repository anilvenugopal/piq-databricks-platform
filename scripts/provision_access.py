#!/usr/bin/env python3
"""
Access-portal integration: turn an approved request into a config change.

The portal (Entra SSO front end -> GitHub issue -> approver adds `approved`)
calls this from .github/workflows/provision-access.yml. The workflow opens a
pull request; CODEOWNERS routes it to the right approver; merging and applying
the listed stacks makes it real. Comments in the YAML files are preserved.

Request types:
  persona   a person joins a persona group            -> personas.yaml        (apply 20)
  sandbox   a person gets dev_sandbox.u_<user>         -> sandbox_users.yaml   (apply 20, 30, 40)
  product   a domain or consumer domain may read a     -> products/<domain>.yaml (apply 20)
            product (approved by the producing domain)
  sar       a group gets a sensitive access role       -> sars.yaml            (apply 20)
            (approved by governance)

Consumer-group membership is NOT a request type: the consumer lead owns those
groups in Entra and adds people directly (or via Entra self-service).

    python3 scripts/provision_access.py persona --upn jane@corp.com --name data-analyst
    python3 scripts/provision_access.py sandbox --upn jane@corp.com --issue 12
    python3 scripts/provision_access.py product --name loss_ratio --consumer exec_reporting
    python3 scripts/provision_access.py sar --name financial_metrics --env prd --group consumer:exec_reporting:analyst
Add --remove to reverse any of them.
"""
import argparse
import pathlib
import sys

from ruamel.yaml import YAML

ROOT = pathlib.Path(__file__).resolve().parent.parent
CFG = ROOT / "config"
yaml = YAML()
yaml.preserve_quotes = True
yaml.indent(mapping=2, sequence=4, offset=2)


def load(path):
    return yaml.load(path.read_text())


def save(path, data):
    with path.open("w") as f:
        yaml.dump(data, f)


def toggle(seq, item, remove):
    if remove and item in seq:
        seq.remove(item)
        return True
    if not remove and item not in seq:
        seq.append(item)
        return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("type", choices=["persona", "sandbox", "product", "sar"])
    ap.add_argument("--upn")
    ap.add_argument("--name", help="persona, product or SAR name")
    ap.add_argument("--consumer", help="product: domain or consumer domain to approve")
    ap.add_argument("--env", default="prd", help="sar: environment")
    ap.add_argument("--group", help="sar: group reference, e.g. consumer:exec_reporting:analyst")
    ap.add_argument("--issue", default="")
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()

    if a.type == "persona":
        path = CFG / "personas.yaml"
        data = load(path)
        if a.name not in data["personas"]:
            sys.exit(f"unknown persona {a.name}")
        p = data["personas"][a.name]
        if p.get("members") is None:
            p["members"] = []
        changed = toggle(p["members"], a.upn, a.remove)
    elif a.type == "sandbox":
        path = CFG / "sandbox_users.yaml"
        data = load(path) or {}
        users = data.get("users") or []
        present = [u for u in users if u["upn"] == a.upn]
        changed = bool(present) == a.remove
        if a.remove:
            users = [u for u in users if u["upn"] != a.upn]
        elif not present:
            users.append({"upn": a.upn, "requested_via": f"issue #{a.issue}" if a.issue else "manual"})
        data["users"] = users
    elif a.type == "product":
        files = [f for f in sorted((CFG / "products").glob("*.yaml")) if a.name in (load(f).get("products") or {})]
        if not files:
            sys.exit(f"unknown product {a.name}")
        path = files[0]
        data = load(path)
        prod = data["products"][a.name]
        if prod.get("consumers") is None:
            prod["consumers"] = []
        changed = toggle(prod["consumers"], a.consumer, a.remove)
    else:
        path = CFG / "sars.yaml"
        data = load(path)
        if a.name not in data["sars"]:
            sys.exit(f"unknown SAR {a.name}")
        members = data["sars"][a.name].setdefault("members", {})
        if members.get(a.env) is None:
            members[a.env] = []
        changed = toggle(members[a.env], a.group, a.remove)

    save(path, data)
    print(f"{'changed' if changed else 'no change'}: {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
