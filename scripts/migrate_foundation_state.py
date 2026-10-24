#!/usr/bin/env python3
"""
One-off: split the OLD state of stack 10-foundation (one state for every environment) into the NEW
per-environment states, without touching any real Azure resource.

    python3 scripts/migrate_foundation_state.py                 # dry run: show what would move where
    python3 scripts/migrate_foundation_state.py --execute       # do it
    python3 scripts/migrate_foundation_state.py --state-file old.tfstate --out-dir out   # offline (tests)

Why: stack 10 used to keep both environments in 10-foundation.tfstate. It now keeps one state per
environment (10-foundation/<env>/env.tfstate, see util/scope.py). The real resources do not change, so
the records are MOVED instead of destroying and recreating workspaces, storage and Key Vaults.

What it does, per environment:
  * every resource instance whose key is the environment ("dev") or starts with it ("dev-host",
    "dev-claims") is moved with `terraform state mv` into that environment's new state
  * the resource group is NOT moved: bootstrap/ now creates it, and stack 10 only looks it up. The
    script prints the `terraform import` commands for bootstrap instead.
  * with --execute the new states are pushed to the backend (a key that already holds state is never
    overwritten) and the old state is left in place; delete it yourself once the new ones plan clean.

After it: apply bootstrap (with the imports), then `python3 scripts/apply.py 10-foundation --scope env
--env <env>` for each environment. The plan must show NO changes; the apply only refreshes the outputs
that later stacks read.
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from util.scope import state_key  # noqa: E402

STACK = "10-foundation"
OLD_KEY = "10-foundation.tfstate"
RG_TYPE = "azurerm_resource_group"
TF = "terraform"


def addr(res: dict, inst: dict) -> str:
    base = f"{res['module'] + '.' if res.get('module') else ''}{res['type']}.{res['name']}"
    k = inst.get("index_key")
    if k is None:
        return base
    return f'{base}["{k}"]' if isinstance(k, str) else f"{base}[{k}]"


def owner(key, envs: list[str]) -> str | None:
    """The environment an instance key belongs to ('dev' or 'dev-host'), or None."""
    if not isinstance(key, str):
        return None
    for e in sorted(envs, key=len, reverse=True):
        if key == e or key.startswith(e + "-"):
            return e
    return None


def plan_moves(state: dict, envs: list[str]) -> tuple[dict[str, list[str]], list[str], list[str]]:
    """(addresses per environment, resource groups left for bootstrap, addresses nobody owns)."""
    moves: dict[str, list[str]] = {e: [] for e in envs}
    rgs: list[str] = []
    orphans: list[str] = []
    for res in state.get("resources", []):
        if res.get("mode") != "managed":
            continue
        for inst in res.get("instances", []):
            a = addr(res, inst)
            e = owner(inst.get("index_key"), envs)
            if res["type"] == RG_TYPE:
                rgs.append(a)
            elif e is None:
                orphans.append(a)
            else:
                moves[e].append(a)
    return moves, rgs, orphans


def tf(cwd: Path, *args: str, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run([TF, f"-chdir={cwd}", *args], capture_output=capture, text=True, check=False)


def init_backend(work: Path, key: str, cfg: dict) -> None:
    (work / "main.tf").write_text('terraform {\n  backend "azurerm" {}\n}\n')
    s = cfg["state"]
    r = tf(work, "init", "-reconfigure", "-input=false", "-no-color",
           f"-backend-config=resource_group_name={s['resource_group']}",
           f"-backend-config=storage_account_name={s['storage_account']}",
           f"-backend-config=container_name={s['container']}",
           f"-backend-config=key={key}", "-backend-config=use_azuread_auth=true")
    if r.returncode:
        sys.exit(f"terraform init failed for key {key}:\n{r.stdout}{r.stderr}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--execute", action="store_true", help="push the new states to the backend")
    ap.add_argument("--state-file", type=Path, help="use this local state file instead of pulling the old state")
    ap.add_argument("--out-dir", type=Path, help="write the new state files here (default: a temp dir)")
    a = ap.parse_args()

    cfg = yaml.safe_load((ROOT / "config" / "platform.yaml").read_text())
    envs = sorted(cfg["environments"])
    work = Path(tempfile.mkdtemp(prefix="migrate10-"))
    out = a.out_dir or work
    out.mkdir(parents=True, exist_ok=True)

    old = out / "old.tfstate"
    if a.state_file:
        old.write_text(a.state_file.read_text())
    else:
        init_backend(work, OLD_KEY, cfg)
        r = tf(work, "state", "pull")
        if r.returncode or not r.stdout.strip():
            sys.exit(f"could not pull {OLD_KEY}:\n{r.stderr}")
        old.write_text(r.stdout)

    state = json.loads(old.read_text())
    moves, rgs, orphans = plan_moves(state, envs)
    sub = cfg["azure"]["subscription_id"]

    print(f"Old state: {sum(len(v) for v in moves.values()) + len(rgs) + len(orphans)} resource instances")
    for e in envs:
        print(f"  {e}: {len(moves[e])} move to {state_key(STACK, e, 'env')}")
    if orphans:
        print("ERROR: these resources belong to no environment; stop and look at them:", file=sys.stderr)
        print("\n".join(f"  {o}" for o in orphans), file=sys.stderr)
        return 1

    print("\nResource groups are now created by bootstrap/. Import them there (after this script):")
    for g in rgs:
        e = g.split('"')[1]
        print(f"  terraform -chdir=bootstrap import '{'azurerm_resource_group.env[\"' + e + '\"]'}' "
              f"/subscriptions/{sub}/resourceGroups/rg-{cfg['prefix']}-{e}")

    if not a.execute and not a.state_file:
        print("\nDry run. Nothing was changed. Re-run with --execute to move the records.")
        return 0

    # Move every instance into its environment's state file (official `terraform state mv`).
    scratch = Path(tempfile.mkdtemp(prefix="migrate10-mv-"))
    (scratch / "main.tf").write_text("")
    work_old = scratch / "old.tfstate"
    work_old.write_text(old.read_text())
    for e in envs:
        newf = out / f"{e}.tfstate"
        if newf.exists():
            newf.unlink()
        for ad in moves[e]:
            r = tf(scratch, "state", "mv", f"-state={work_old}", f"-state-out={newf}", "-lock=false", ad, ad)
            if r.returncode:
                sys.exit(f"state mv failed for {ad}:\n{r.stdout}{r.stderr}")
        n = len(json.loads(newf.read_text()).get("resources", [])) if newf.exists() else 0
        print(f"  wrote {newf} ({n} resources)")
    left = json.loads(work_old.read_text())
    print(f"  left in the old state: {sum(len(r.get('instances', [])) for r in left.get('resources', []))} instances (the resource groups)")

    if not a.execute:
        print("\nOffline run: new state files written, nothing pushed.")
        return 0

    for e in envs:
        key = state_key(STACK, e, "env")
        d = Path(tempfile.mkdtemp(prefix=f"migrate10-push-{e}-"))
        init_backend(d, key, cfg)
        existing = tf(d, "state", "pull")
        if existing.stdout.strip() and json.loads(existing.stdout).get("resources"):
            print(f"REFUSING to overwrite {key}: it already holds state.", file=sys.stderr)
            return 1
        r = tf(d, "state", "push", str(out / f"{e}.tfstate"))
        if r.returncode:
            sys.exit(f"state push failed for {key}:\n{r.stdout}{r.stderr}")
        print(f"  pushed {key}")
    print("\nDone. Next: import the resource groups into bootstrap (commands above), apply bootstrap, then plan each environment:")
    print(f"  python3 scripts/plan.py {STACK} --scope env --env <env>      # must show no changes")
    print(f"The old state {OLD_KEY} is untouched; delete that blob once the new states plan clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
