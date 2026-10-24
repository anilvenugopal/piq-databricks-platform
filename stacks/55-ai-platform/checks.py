"""
Post-apply checks for stack 55-ai-platform.

Verifies that App Space and vector search endpoint names are present in
the stack outputs for each environment. Expected names are derived from
config/ — adding a domain automatically extends the expected set.

Note: some features (Lakebase) may be unavailable in private preview
accounts. Checks cover only resources reflected in the outputs.
"""
from util.config_reader import Config
from util.validation import CheckResult


def check_app_spaces(outputs: dict) -> CheckResult:
    cfg = Config()
    ai = outputs.get("ai", {})
    if not ai:
        return CheckResult("app_spaces", "RETRY", "no ai outputs yet")

    failures = []
    for env in cfg.envs:
        env_out = ai.get(env, {})
        app_spaces = env_out.get("app_spaces", {})
        expected_domains = set(cfg.domains)
        actual_domains = set(app_spaces.keys())
        missing = expected_domains - actual_domains
        if missing:
            failures.append(
                f"{env}: missing app spaces for {', '.join(sorted(missing))}"
            )

    if failures:
        return CheckResult("app_spaces", "FAIL", "; ".join(failures))

    total = sum(len(ai.get(e, {}).get("app_spaces", {})) for e in cfg.envs)
    return CheckResult("app_spaces", "PASS",
                       f"{total} app spaces present across all environments")


def check_vector_search(outputs: dict) -> CheckResult:
    cfg = Config()
    ai = outputs.get("ai", {})
    if not ai:
        return CheckResult("vector_search", "RETRY", "no ai outputs yet")

    missing = [env for env in cfg.envs if not ai.get(env, {}).get("vector_search")]
    if missing:
        return CheckResult("vector_search", "FAIL",
                           f"vector search endpoint missing for: {', '.join(missing)}")

    return CheckResult("vector_search", "PASS",
                       f"vector search endpoints present for: {', '.join(cfg.envs)}")


CHECKS = [
    check_app_spaces,
    check_vector_search,
]
