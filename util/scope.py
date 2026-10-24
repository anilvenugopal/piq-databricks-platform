"""
Scopes and state keys, shared by every wrapper (scripts/tf.sh, plan.py, apply.py, check.py).

A deployment target is (stack, environment, scope). The scope says which slice of the platform a
Terraform run owns, so a run can never touch another slice:

    shared         account-wide things that span environments          (no environment)
    env            one environment's infrastructure
    access         people and approvals in one environment (stack 25)
    domain:<name>  one domain in one environment

Each target has its own Terraform state:

    <stack>/shared.tfstate                      scope shared
    <stack>/<env>/env.tfstate                   scope env
    <stack>/<env>/access.tfstate                scope access
    <stack>/<env>/domain-<name>.tfstate         scope domain:<name>
"""
import re
from dataclasses import dataclass
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCOPE_KINDS = ("shared", "env", "access", "domain")
_DOMAIN = re.compile(r"^domain:[a-z][a-z0-9_]{1,30}$")


def kind(scope: str) -> str:
    """shared | env | access | domain"""
    return "domain" if scope.startswith("domain:") else scope


def validate_scope(scope: str) -> str | None:
    """Return an error message, or None when the scope string is well formed."""
    if scope in ("shared", "env", "access") or _DOMAIN.match(scope):
        return None
    return f"scope must be shared, env, access or domain:<name> (got '{scope}')"


def slug(scope: str) -> str:
    return "domain-" + scope.split(":", 1)[1] if scope.startswith("domain:") else scope


def state_key(stack: str, env: str | None, scope: str) -> str:
    if scope == "shared":
        return f"{stack}/shared.tfstate"
    if not env:
        raise ValueError(f"scope '{scope}' needs an environment")
    return f"{stack}/{env}/{slug(scope)}.tfstate"


@dataclass(frozen=True)
class Target:
    stack: str
    env: str | None
    scope: str

    @property
    def key(self) -> str:
        return state_key(self.stack, self.env, self.scope)

    @property
    def sid(self) -> str:
        """Same identifier the naming module stamps on every item it owns."""
        return "shared" if self.scope == "shared" else f"{self.env}/{self.scope}"

    def label(self) -> str:
        return f"{self.stack} [{self.sid}]"


def stack_scopes(stack: str) -> list[str]:
    """Scope kinds a stack supports, from stacks/<stack>/stack.yaml."""
    p = ROOT / "stacks" / stack / "stack.yaml"
    data = (yaml.safe_load(p.read_text()) or {}) if p.exists() else {}
    return list(data.get("scopes", []))


def check_target(stack: str, env: str | None, scope: str, envs: list[str], domains: list[str]) -> list[str]:
    """Problems with a requested target; empty list means it is valid."""
    problems = []
    bad = validate_scope(scope)
    if bad:
        return [bad]
    if kind(scope) not in stack_scopes(stack):
        problems.append(f"stack {stack} does not support scope '{kind(scope)}' (supports: {', '.join(stack_scopes(stack)) or 'none declared'})")
    if scope == "shared":
        if env:
            problems.append("scope 'shared' takes no environment")
    elif not env:
        problems.append(f"scope '{scope}' needs --env")
    elif env not in envs:
        problems.append(f"unknown environment '{env}' (known: {', '.join(envs)})")
    if kind(scope) == "domain" and scope.split(":", 1)[1] not in domains:
        problems.append(f"unknown domain '{scope.split(':', 1)[1]}' (known: {', '.join(domains)})")
    return problems
