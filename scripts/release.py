#!/usr/bin/env python3
"""
Cut a release: an immutable git tag rel-YYYY.MM.DD.N on the current commit.

    python3 scripts/release.py              # tag HEAD (must be clean, config must validate)
    python3 scripts/release.py --push       # ...and push the tag
    python3 scripts/release.py --list       # releases, newest last

Only a tagged commit can go to an environment that has promotes_from (config/platform.yaml), and only
after it was deployed to those environments. Any commit may go to an environment that accepts anything
(dev). Cut a release when you have something worth promoting.
"""
import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from util import release  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--push", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--message", default="")
    a = ap.parse_args()

    if a.list:
        tags = [t for t in release._git("tag", "--list", "rel-*").splitlines() if release.is_release_tag(t)]
        print("\n".join(sorted(tags)) or "no releases yet")
        return 0

    if not release.is_clean():
        print("ERROR: the working tree has uncommitted changes; commit them first.", file=sys.stderr)
        return 1
    if subprocess.run([sys.executable, str(ROOT / "scripts" / "validate_config.py")]).returncode:
        print("ERROR: config does not validate; fix it before releasing.", file=sys.stderr)
        return 1
    tag = release.next_tag()
    release.create_tag(tag, a.message)
    print(f"Created {tag} at {release.head_sha()[:10]}")
    if a.push:
        release._git("push", "origin", tag)
        print(f"Pushed {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
