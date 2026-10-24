#!/usr/bin/env python3
"""
Show which release is deployed where: the latest successful deploy of every target.

    python3 scripts/status.py [--env dev] [--stack 40-unity-catalog]

Reads the deploy records (util/deploys.py). A target with no record shows "-".
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from util import deploys  # noqa: E402
from util.targets import all_targets, naming_all  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env")
    ap.add_argument("--stack")
    a = ap.parse_args()
    naming = naming_all()
    st = deploys.store(naming["platform"])
    targets = all_targets(naming, [a.stack] if a.stack else None, a.env)
    print(f"{'stack':<18} {'environment':<12} {'scope':<28} {'release':<22} deployed")
    for t in targets:
        rec = deploys.latest(st, t.stack, t.env, t.scope)
        print(f"{t.stack:<18} {t.env or '-':<12} {t.scope:<28} {(rec or {}).get('release', '-'):<22} {(rec or {}).get('ts', '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
