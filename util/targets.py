"""
Resolve and enumerate deployment targets (stack, environment, scope).

A target is valid when the stack supports the scope kind, the environment and domain exist, and the
scope string is well formed (util/scope.py). The environments and domains come from config/ through
the naming module, so adding a domain or an environment needs no code change.
"""
from pathlib import Path

from util.naming_eval import evaluate
from util.scope import Target, check_target, kind, stack_scopes
from util.validation import Context, valid_stacks

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config"


def naming_all() -> dict:
    ok, out = evaluate(CONFIG)
    if not ok:
        raise SystemExit(f"config/ does not evaluate:\n{out}")
    return out


def resolve(stack: str, env: str | None, scope: str, naming: dict | None = None) -> tuple[Target | None, dict, list[str]]:
    """Return (target, unfiltered naming output, problems)."""
    naming = naming or naming_all()
    if stack not in valid_stacks():
        return None, naming, [f"'{stack}' is not a valid stack (valid: {', '.join(valid_stacks())})"]
    problems = check_target(stack, env, scope, naming["env_keys"], naming["domain_keys"])
    if problems:
        return None, naming, problems
    t = Target(stack, env, scope)
    if stack == "70-observability" and env != naming["prod_env"]:
        return None, naming, [f"70-observability only runs in the prod environment ({naming['prod_env']})"]
    return t, naming, []


def context(t: Target, naming: dict) -> Context:
    """The naming output filtered to the target: what this run is supposed to have created."""
    ok, filtered = evaluate(CONFIG, t.env, t.scope)
    if not ok:
        raise SystemExit(f"config/ does not evaluate for {t.label()}:\n{filtered}")
    return Context(target=t, naming=filtered, naming_all=naming)


def all_targets(naming: dict, stacks: list[str] | None = None, env: str | None = None) -> list[Target]:
    """Every target of every stack (optionally one environment): what a full rollout touches."""
    envs = [env] if env else naming["env_keys"]
    out: list[Target] = []
    for stack in stacks or valid_stacks():
        for k in stack_scopes(stack):
            if k == "shared" and not env:
                out.append(Target(stack, None, "shared"))
            elif k in ("env", "access"):
                for e in envs:
                    if stack == "70-observability" and e != naming["prod_env"]:
                        continue
                    out.append(Target(stack, e, k))
            elif k == "domain":
                out += [Target(stack, e, f"domain:{d}") for e in envs for d in naming["domain_keys"]]
    return out


def stack_order(stack: str) -> int:
    return valid_stacks().index(stack)
