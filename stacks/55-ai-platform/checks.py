"""
Post-apply checks for stack 55-ai-platform (scopes env, domain:<name>).

Verifies that the App Space of each domain with app_space: true (domain scope) and the Vector Search
endpoint (env scope, when enabled) are present in the stack outputs.

Note: some features (Lakebase) may be unavailable in private preview accounts. Checks cover only
resources reflected in the outputs.
"""
from util.validation import CheckResult, Context


def check_app_spaces(outputs: dict, ctx: Context) -> CheckResult:
    if not ctx.scope.startswith("domain:"):
        return CheckResult("app_spaces", "PASS", "app spaces belong to domain scopes")
    domain = ctx.scope.split(":", 1)[1]
    if not ctx.naming["domains"].get(domain, {}).get("app_space", False):
        return CheckResult("app_spaces", "PASS", f"{domain} has app_space: false")
    spaces = (outputs.get("ai") or {}).get("app_spaces")
    if spaces is None:
        return CheckResult("app_spaces", "RETRY", "no ai outputs yet")
    if domain not in spaces:
        return CheckResult("app_spaces", "FAIL", f"missing app space for {domain}")
    return CheckResult("app_spaces", "PASS", f"app space present for {domain}")


def check_vector_search(outputs: dict, ctx: Context) -> CheckResult:
    if ctx.scope != "env" or not ctx.naming["workspace_objects"]["vector_search"]["enabled"]:
        return CheckResult("vector_search", "PASS", "no Vector Search endpoint expected in this scope")
    ai = outputs.get("ai")
    if ai is None:
        return CheckResult("vector_search", "RETRY", "no ai outputs yet")
    if not ai.get("vector_search"):
        return CheckResult("vector_search", "FAIL", f"vector search endpoint missing for {ctx.env}")
    return CheckResult("vector_search", "PASS", f"vector search endpoint present for {ctx.env}")


CHECKS = [
    check_app_spaces,
    check_vector_search,
]
