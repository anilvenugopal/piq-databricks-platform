"""
Deploy records and the promotion gate.

Every apply writes one record: which release (or commit) went to which (stack, environment, scope),
when, by whom, and whether it passed. The promotion gate reads those records to decide whether a
release may go to an environment: it must already have been deployed successfully to every
environment listed in that environment's promotes_from (config/platform.yaml).

Records live in the Terraform state storage account (container "deployments"), so a local run and a
pipeline run see the same history. For tests and offline use, set PIQ_DEPLOY_STORE=local to keep
them in a directory (PIQ_DEPLOY_DIR, default audit/deploys).
"""
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from util.scope import Target, slug

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = "deployments"


def _prefix(stack: str, env: str | None, scope: str) -> str:
    return f"{stack}/{env or 'shared'}/{slug(scope)}"


class LocalStore:
    def __init__(self, root: Path):
        self.root = root

    def put(self, rec: dict) -> str:
        d = self.root / _prefix(rec["stack"], rec["env"], rec["scope"])
        d.mkdir(parents=True, exist_ok=True)
        name = f"{rec['ts'].replace(':', '')}.json"
        (d / name).write_text(json.dumps(rec, indent=2))
        return str(d / name)

    def list(self, stack: str, env: str | None, scope: str) -> list[dict]:
        d = self.root / _prefix(stack, env, scope)
        return [json.loads(p.read_text()) for p in sorted(d.glob("*.json"))] if d.is_dir() else []


class BlobStore:
    """Azure blob storage through the az CLI (Entra auth, no keys)."""

    def __init__(self, account: str):
        self.account = account

    def _az(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["az", *args, "--account-name", self.account, "--auth-mode", "login"],
                              capture_output=True, text=True, check=False)

    def put(self, rec: dict) -> str:
        self._az("storage", "container", "create", "--name", CONTAINER)
        blob = f"{_prefix(rec['stack'], rec['env'], rec['scope'])}/{rec['ts'].replace(':', '')}.json"
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(rec, f)
            path = f.name
        r = self._az("storage", "blob", "upload", "--container-name", CONTAINER, "--name", blob, "--file", path, "--overwrite")
        os.unlink(path)
        if r.returncode:
            raise RuntimeError(f"could not write deploy record: {r.stderr.strip()}")
        return f"{self.account}/{CONTAINER}/{blob}"

    def list(self, stack: str, env: str | None, scope: str) -> list[dict]:
        r = self._az("storage", "blob", "list", "--container-name", CONTAINER,
                     "--prefix", _prefix(stack, env, scope) + "/", "--query", "[].name", "-o", "json")
        if r.returncode:
            if "ContainerNotFound" in r.stderr or "does not exist" in r.stderr:
                return []  # nothing has been deployed yet
            raise RuntimeError(f"could not read deploy records (is `az login` current and does it reach {self.account}?): {r.stderr.strip()}")
        out = []
        for name in sorted(json.loads(r.stdout or "[]")):
            d = self._az("storage", "blob", "download", "--container-name", CONTAINER, "--name", name, "--file", "/dev/stdout", "--no-progress")
            if d.returncode:
                raise RuntimeError(f"could not read deploy record {name}: {d.stderr.strip()}")
            try:
                out.append(json.loads(d.stdout))
            except json.JSONDecodeError:
                continue
        return out


def store(platform_cfg: dict | None = None):
    if os.environ.get("PIQ_DEPLOY_STORE") == "local":
        return LocalStore(Path(os.environ.get("PIQ_DEPLOY_DIR", ROOT / "audit" / "deploys")))
    if platform_cfg is None:
        import yaml
        platform_cfg = yaml.safe_load((ROOT / "config" / "platform.yaml").read_text())
    return BlobStore(platform_cfg["state"]["storage_account"])


def record(t: Target, release: str, sha: str, outcome: str, *, hotfix: bool = False,
           approver: str = "", checks: list[dict] | None = None) -> dict:
    return {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stack": t.stack, "env": t.env, "scope": t.scope,
        "release": release, "sha": sha, "outcome": outcome,
        "hotfix": hotfix, "approver": approver,
        "actor": os.environ.get("GITHUB_ACTOR") or os.environ.get("USER", "unknown"),
        "run_url": os.environ.get("GITHUB_RUN_URL", ""),
        "checks": checks or [],
    }


def check_promotion(st, t: Target, release: str, env_cfg: dict, *, hotfix: bool = False, approver: str = "") -> list[str]:
    """Problems that stop `release` going to `t`; an empty list means it may go."""
    if t.scope == "shared" or not t.env:
        return []  # shared scope has no environment to promote through
    cfg = env_cfg.get(t.env, {})
    sources = list(cfg.get("promotes_from") or [])
    if hotfix:
        if not cfg.get("allow_hotfix", False):
            return [f"environment {t.env} does not allow hotfix deploys (allow_hotfix: false)"]
        if not approver:
            return ["a hotfix deploy needs --approver <name>"]
        return []
    if not sources:
        return []
    if not release.startswith("rel-"):
        return [f"environment {t.env} only accepts a release tag (rel-YYYY.MM.DD.N), not {release}"]
    problems = []
    for src in sources:
        passed = [r for r in st.list(t.stack, src, t.scope) if r.get("release") == release and r.get("outcome") == "PASS"]
        if not passed:
            problems.append(f"{release} has not been deployed successfully to {src} for {t.stack} [{t.scope}]")
    return problems


def latest(st, stack: str, env: str | None, scope: str) -> dict | None:
    recs = [r for r in st.list(stack, env, scope) if r.get("outcome") == "PASS"]
    return recs[-1] if recs else None
