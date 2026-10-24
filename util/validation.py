"""
Core validation primitives shared by all per-stack checks.

Context:       what a check needs to know: the deployment target and the naming output
               for it (the names, groups, catalogs... this run is supposed to have created).
CheckResult:   the return type every check function must return.
run_checks:    executes a list of check functions with retry logic,
               returns results suitable for the audit log.
valid_stacks:  returns the ordered list of stack names from stacks/.
resolve_stack: validates a stack name and prints a clear error if invalid.
"""
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from util.scope import Target

_ROOT = Path(__file__).resolve().parents[1]

MAX_RETRIES = 5
RETRY_DELAY_SECONDS = 15


def valid_stacks() -> list[str]:
    """Stack names in numbered order — directories under stacks/ that contain .tf files."""
    stacks_dir = _ROOT / "stacks"
    return sorted(
        d.name for d in stacks_dir.iterdir()
        if d.is_dir() and any(d.glob("*.tf"))
    )


def resolve_stack(name: str) -> str | None:
    """Return the stack name if valid, else print a clear error with the valid list."""
    stacks = valid_stacks()
    if name in stacks:
        return name
    print(f"ERROR: '{name}' is not a valid stack.", file=sys.stderr)
    print(f"Valid stacks: {', '.join(stacks)}", file=sys.stderr)
    return None


@dataclass
class Context:
    """Passed to every check as the second argument: check(outputs, ctx)."""
    target: Target
    naming: dict                                   # naming outputs filtered to this target
    naming_all: dict = field(default_factory=dict)  # unfiltered, for cross-scope facts

    @property
    def env(self) -> str | None:
        return self.target.env

    @property
    def scope(self) -> str:
        return self.target.scope

    @property
    def prefix(self) -> str:
        return self.naming["prefix"]


@dataclass
class CheckResult:
    name: str
    status: str    # PASS | FAIL | RETRY
    message: str


def run_checks(
    checks: list[Callable[[dict, Context], CheckResult]],
    outputs: dict,
    ctx: Context,
    verbose: bool = True,
) -> list[dict]:
    """
    Run each check function against the provided Terraform outputs and context.
    RETRY results are retried up to MAX_RETRIES times with a delay.
    Returns a list of result dicts for the audit log.
    """
    results: list[dict] = []
    for check_fn in checks:
        result = _with_retry(check_fn, outputs, ctx, verbose=verbose)
        if verbose:
            icon = "✓" if result.status == "PASS" else "✗"
            print(f"  {icon} {result.name}: {result.message}")
        results.append({
            "name": result.name,
            "status": result.status,
            "message": result.message,
        })

    if verbose:
        passed = sum(1 for r in results if r["status"] == "PASS")
        failed = len(results) - passed
        print(f"\n  {passed} passed, {failed} failed")

    return results


def _with_retry(
    check_fn: Callable[[dict, Context], CheckResult],
    outputs: dict,
    ctx: Context,
    verbose: bool,
) -> CheckResult:
    result = CheckResult(name=check_fn.__name__, status="FAIL", message="not run")
    for attempt in range(MAX_RETRIES):
        result = check_fn(outputs, ctx)
        if result.status != "RETRY":
            return result
        if attempt < MAX_RETRIES - 1:
            if verbose:
                print(
                    f"  ~ {result.name}: {result.message}"
                    f" — retrying in {RETRY_DELAY_SECONDS}s"
                    f" ({attempt + 1}/{MAX_RETRIES - 1})"
                )
            time.sleep(RETRY_DELAY_SECONDS)

    return CheckResult(
        name=result.name,
        status="FAIL",
        message=f"{result.message} (gave up after {MAX_RETRIES} retries)",
    )
