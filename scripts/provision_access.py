#!/usr/bin/env python3
"""
Access-portal integration: turn an approved request into an entitlement change.

The portal (Entra SSO front end -> GitHub issue -> approver adds `approved`) calls this from
.github/workflows/provision-access.yml. The workflow opens a pull request; CODEOWNERS routes it to the
right approver (stricter for prd); merging and deploying stack 25-access for that environment makes it real.
Comments in the YAML files are preserved.

All of this is ENTITLEMENT data (who is in which group, which approvals were given), kept in
config/entitlements/<env>/. When an identity-governance tool (SailPoint, Saviynt, ...) takes this job over,
this script, that folder and stack 25-access go away together.

Request types (all take --env):
  persona   a person holds a persona in that environment    -> entitlements/<env>/personas.yaml
            (--name data-analyst, or <domain>/<persona> for a domain persona)
  sandbox   a person gets <env>_sandbox.u_<user>             -> entitlements/<env>/sandboxes.yaml   (nonprod only)
  product   a domain or consumer domain may read a product   -> entitlements/<env>/product_access.yaml
            (approved by the producing domain)
  sar       a group gets a sensitive access role             -> entitlements/<env>/sars.yaml
            (approved by governance)
  admin     a person administers a domain's database         -> entitlements/<env>/admins.yaml     (--domain)

Consumer-group membership is NOT a request type: the consumer lead owns those groups in Entra and adds
people directly (or via Entra self-service).

    python3 scripts/provision_access.py persona --env prd --upn jane@corp.com --name data-analyst
    python3 scripts/provision_access.py sandbox --env dev --upn jane@corp.com --issue 12
    python3 scripts/provision_access.py product --env prd --name loss_ratio --consumer exec_reporting
    python3 scripts/provision_access.py sar --env prd --name financial_metrics --group consumer:exec_reporting:analyst
    python3 scripts/provision_access.py admin --env dev --domain claims --upn jane@corp.com
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
    ap.add_argument("type", choices=["persona", "sandbox", "product", "sar", "admin"])
    ap.add_argument("--env", required=True, help="environment the request is for")
    ap.add_argument("--upn")
    ap.add_argument("--name", help="persona, product or SAR name")
    ap.add_argument("--domain", help="admin: the domain")
    ap.add_argument("--consumer", help="product: domain or consumer domain to approve")
    ap.add_argument("--group", help="sar: group reference, e.g. consumer:exec_reporting:analyst")
    ap.add_argument("--issue", default="")
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()

    base = CFG / "entitlements" / a.env
    if not base.is_dir():
        sys.exit(f"unknown environment {a.env}: no config/entitlements/{a.env}/")

    if a.type == "persona":
        known = set(load(CFG / "personas.yaml")["personas"])
        if "/" not in a.name and a.name not in known:
            sys.exit(f"unknown persona {a.name}")
        path = base / "personas.yaml"
        data = load(path)
        if data.get("users") is None or data["users"] == {}:
            data["users"] = {}
        users = data["users"]
        if a.upn not in users:
            users[a.upn] = []
        changed = toggle(users[a.upn], a.name, a.remove)
        if not users[a.upn]:
            del users[a.upn]
    elif a.type == "sandbox":
        path = base / "sandboxes.yaml"
        data = load(path)
        users = data.get("users") or []
        present = [u for u in users if u["upn"] == a.upn]
        changed = bool(present) == a.remove
        if a.remove:
            users = [u for u in users if u["upn"] != a.upn]
        elif not present:
            users.append({"upn": a.upn, "requested_via": f"issue #{a.issue}" if a.issue else "manual"})
        data["users"] = users
    elif a.type == "product":
        path = base / "product_access.yaml"
        data = load(path)
        products = data.get("products")
        if products is None:
            data["products"] = products = {}
        if a.name not in products:
            products[a.name] = []
        changed = toggle(products[a.name], a.consumer, a.remove)
    elif a.type == "sar":
        path = base / "sars.yaml"
        data = load(path)
        members = data.get("members")
        if members is None:
            data["members"] = members = {}
        if a.name not in members:
            members[a.name] = []
        changed = toggle(members[a.name], a.group, a.remove)
    else:
        path = base / "admins.yaml"
        data = load(path)
        doms = data.get("domains")
        if doms is None:
            data["domains"] = doms = {}
        if a.domain not in doms:
            doms[a.domain] = []
        changed = toggle(doms[a.domain], a.upn, a.remove)
        if not doms[a.domain]:
            del doms[a.domain]

    save(path, data)
    print(f"{'changed' if changed else 'no change'}: {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
