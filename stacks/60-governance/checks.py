"""
Post-apply checks for stack 60-governance (scopes env, domain:<name>).

Verifies that a column-mask policy exists for every (catalog x mask) pair this scope owns. The expected
set comes from the naming module's ABAC policies for the scope, so adding a mask or a catalog extends it.
"""
from util.validation import CheckResult, Context


def check_mask_policies(outputs: dict, ctx: Context) -> CheckResult:
    expected = set(ctx.naming["abac_policies"])
    if not expected:
        return CheckResult("mask_policies", "PASS", f"this scope owns no mask policies ({ctx.target.sid})")
    policies = outputs.get("policies", [])
    if not policies:
        return CheckResult("mask_policies", "RETRY", "no policies in outputs yet")
    missing = expected - set(policies)
    if missing:
        sample = sorted(missing)[:5]
        more = f" (and {len(missing) - 5} more)" if len(missing) > 5 else ""
        return CheckResult("mask_policies", "FAIL", f"missing policies: {', '.join(sample)}{more}")
    return CheckResult("mask_policies", "PASS", f"{len(policies)} mask policies present, all expected keys found")


CHECKS = [
    check_mask_policies,
]
