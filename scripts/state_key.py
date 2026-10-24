#!/usr/bin/env python3
"""
Print the Terraform state key of a deployment target (used by scripts/tf.sh).

    python3 scripts/state_key.py <stack> <env|-> <scope>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from util.scope import Target, validate_scope


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: state_key.py <stack> <env|-> <scope>", file=sys.stderr)
        return 2
    stack, env, scope = sys.argv[1], sys.argv[2], sys.argv[3]
    bad = validate_scope(scope)
    if bad:
        print(bad, file=sys.stderr)
        return 1
    env = None if env in ("", "-") else env
    try:
        print(Target(stack, env, scope).key)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
