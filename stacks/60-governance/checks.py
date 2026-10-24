"""
Post-apply checks for stack 60-governance.

Verifies that column mask policies exist for every expected
catalog × mask combination. Expected policies are derived from
config/governed_tags.yaml and config/ domain/consumer structure —
adding a mask or a catalog automatically extends the expected set.
"""
import pathlib
import yaml

from util.config_reader import Config
from util.validation import CheckResult

_CFG = pathlib.Path(__file__).resolve().parents[2] / "config"


def _expected_policy_keys(cfg: Config) -> set[str]:
    """
    Produce the set of policy keys the naming module creates.
    Key format: '<catalog-key>|<mask-key>'
    Catalog keys: 'domain:<env>:<domain>', 'vault:<env>', 'anon:prd:<domain>',
                  'consumer:prd:<consumer>'
    Mask keys: one per entry in governed_tags.yaml masks.
    """
    tags_cfg = yaml.safe_load((_CFG / "governed_tags.yaml").read_text()) or {}
    masks = list(tags_cfg.get("masks", {}).keys())
    if not masks:
        return set()

    keys: set[str] = set()
    for env in cfg.envs:
        for domain in cfg.domains:
            cat_key = f"domain:{env}:{domain}"
            for mask in masks:
                keys.add(f"{cat_key}|{mask}")
        vault_key = f"vault:{env}"
        for mask in masks:
            keys.add(f"{vault_key}|{mask}")

    # consumer catalogs (prd only)
    for ck in cfg.consumer_keys:
        for mask in masks:
            keys.add(f"consumer:prd:{ck}|{mask}")

    return keys


def check_mask_policies(outputs: dict) -> CheckResult:
    cfg = Config()
    policies = outputs.get("policies", [])
    if not policies:
        return CheckResult("mask_policies", "RETRY", "no policies in outputs yet")

    actual = set(policies)
    expected = _expected_policy_keys(cfg)
    missing = expected - actual

    if missing:
        sample = sorted(missing)[:5]
        more = f" (and {len(missing) - 5} more)" if len(missing) > 5 else ""
        return CheckResult("mask_policies", "FAIL",
                           f"missing policies: {', '.join(sample)}{more}")

    return CheckResult("mask_policies", "PASS",
                       f"{len(actual)} mask policies present, all expected keys found")


CHECKS = [
    check_mask_policies,
]
