"""
Scope check: before anything is applied, make sure the plan only changes what the requested
target owns.

Every item the naming module produces carries a `sid` (see util/scope.py): the one scope that owns
it. A saved plan lists every resource it would create, change or delete; each resource created from
a for_each carries the key of the item behind it (a schema key, a group key, a catalog key...). This
check looks each changed resource up in the naming output and refuses the plan if any of them belongs
to another environment or scope.

It is a second lock behind the state split, not the first one: with one state per target the plan
cannot contain other targets' resources. It catches mistakes in how a stack was split.

Resources without an instance key (workspace settings, a provider-level singleton) belong to the
run by construction. A key the naming module does not know is reported as `unattributed` (a warning,
not a failure), because some resources key on a derived string.
"""
from dataclasses import dataclass, field

from util.scope import Target

# Output maps whose keys name an owned item, and where to read the owner scope from.
_KEYED = ["groups", "nesting", "access_nesting", "access_user_memberships", "access_test_user_memberships",
          "service_principals", "sp_memberships", "group_workspace_assignments", "sp_workspace_assignments",
          "catalogs", "schemas", "volumes", "usage_scopes", "governed_tags", "abac_policies", "test_users",
          "terraform_identities"]


@dataclass
class ScopeResult:
    violations: list[str] = field(default_factory=list)   # "<address>  belongs to <sid>"
    unattributed: list[str] = field(default_factory=list)
    checked: int = 0

    @property
    def ok(self) -> bool:
        return not self.violations


def owners(naming_all: dict, env: str | None) -> dict[str, str]:
    """instance key -> owning sid, from the UNFILTERED naming output."""
    out: dict[str, str] = {}
    for name in _KEYED:
        for k, v in (naming_all.get(name) or {}).items():
            sid = v.get("sid") if isinstance(v, dict) else None
            if sid:
                out[k] = sid
    for e, ws in (naming_all.get("warehouses") or {}).items():
        for wname, w in ws.items():
            out[f"{e}/{wname}"] = w["sid"]
            if e == env:
                out.setdefault(wname, w["sid"])
    for k in (naming_all.get("catalog_grants") or {}):
        out.setdefault(k, naming_all["catalogs"][k]["sid"])
    return out


def _lookup(key: str, owned: dict[str, str]) -> str | None:
    """Find the owner of an instance key, trying the key itself, then its parts.

    Derived keys look like "<catalog key>|piq_env", "<schema key>|piq_layer", "<sp>|<subject>",
    "<schema key>/<volume>", "<child>><parent>".
    """
    if key in owned:
        return owned[key]
    for sep in ("|", ">"):
        if sep in key:
            head = key.split(sep, 1)[0]
            if head in owned:
                return owned[head]
    if "/" in key:
        head = key.rsplit("/", 1)[0]
        if head in owned:
            return owned[head]
    return None


def check_plan(plan_json: dict, target: Target, naming_all: dict) -> ScopeResult:
    res = ScopeResult()
    owned = owners(naming_all, target.env)
    for rc in plan_json.get("resource_changes", []) or []:
        actions = (rc.get("change") or {}).get("actions") or []
        if rc.get("mode") != "managed" or actions in (["no-op"], ["read"]):
            continue
        key = rc.get("index")
        if not isinstance(key, str):
            continue  # a singleton or counted resource: owned by the run
        res.checked += 1
        sid = _lookup(key, owned)
        if sid is None:
            res.unattributed.append(f"{rc['address']}")
        elif sid != target.sid:
            res.violations.append(f"{rc['address']}  belongs to {sid}, this run owns {target.sid}")
    return res
