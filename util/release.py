"""
Releases: immutable git tags `rel-YYYY.MM.DD.N` that move through the environments.

Any commit may be deployed to an environment that accepts anything (promotes_from empty, e.g. dev).
An environment with promotes_from only accepts a release tag, and only one that was already deployed
successfully to each of those environments (util/deploys.py). The code that runs must be the code of the
tag, so HEAD must be the tagged commit and the working tree must be clean.
"""
import re
import subprocess
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TAG = re.compile(r"^rel-\d{4}\.\d{2}\.\d{2}\.\d+$")


def _git(*args: str) -> str:
    r = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=False)
    if r.returncode:
        raise RuntimeError(r.stderr.strip() or f"git {' '.join(args)} failed")
    return r.stdout.strip()


def is_release_tag(name: str) -> bool:
    return bool(TAG.match(name))


def head_sha() -> str:
    return _git("rev-parse", "HEAD")


def tag_sha(tag: str) -> str:
    return _git("rev-list", "-n", "1", tag)


def is_clean() -> bool:
    return _git("status", "--porcelain", "--untracked-files=no") == ""


def next_tag(today: date | None = None) -> str:
    today = today or date.today()
    prefix = f"rel-{today:%Y.%m.%d}."
    existing = [t for t in _git("tag", "--list", f"{prefix}*").splitlines() if is_release_tag(t)]
    n = max((int(t.rsplit(".", 1)[1]) for t in existing), default=0) + 1
    return f"{prefix}{n}"


def create_tag(tag: str, message: str = "") -> None:
    _git("tag", "-a", tag, "-m", message or f"Release {tag}")


def describe_head() -> str:
    """The release tag at HEAD if there is one, else sha:<short>."""
    tags = [t for t in _git("tag", "--points-at", "HEAD").splitlines() if is_release_tag(t)]
    return sorted(tags)[-1] if tags else f"sha:{head_sha()[:10]}"
