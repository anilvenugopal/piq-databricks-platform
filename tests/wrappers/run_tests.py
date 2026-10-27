#!/usr/bin/env python3
"""
Tests for the deployment wrappers: scopes and state keys, the scope check, the promotion gate,
releases and the safety rules of apply.py. Needs no cloud access (Terraform only evaluates the
naming module, which has no providers).

    python3 tests/wrappers/run_tests.py
"""
import os
import pathlib
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
CONFIG = ROOT / "tests" / "fixtures" / "config"  # a fixed sample, so these tests do not move with the real config

from util import deploys, release  # noqa: E402
from util.naming_eval import evaluate  # noqa: E402
from util.scope import Target, check_target, slug, state_key, validate_scope  # noqa: E402
from util.scope_check import check_plan  # noqa: E402
from util.targets import all_targets  # noqa: E402

failures: list[str] = []


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name)
    if not cond:
        failures.append(f"{name} {detail}")


# ---------------------------------------------------------------------------
print("scopes and state keys")
check("shared state key has no environment", state_key("20-identity", None, "shared") == "20-identity/shared.tfstate")
check("env state key", state_key("10-foundation", "prd", "env") == "10-foundation/prd/env.tfstate")
check("domain state key", state_key("40-unity-catalog", "dev", "domain:claims") == "40-unity-catalog/dev/domain-claims.tfstate")
check("access state key", state_key("25-access", "dev", "access") == "25-access/dev/access.tfstate")
check("a scope that needs an environment refuses a missing one",
      subprocess.run([sys.executable, str(ROOT / "scripts" / "state_key.py"), "10-foundation", "-", "env"], capture_output=True).returncode == 1)
check("malformed scopes are rejected", validate_scope("domain:") is not None and validate_scope("everything") is not None
      and validate_scope("domain:claims") is None and validate_scope("shared") is None)
check("slug", slug("domain:claims") == "domain-claims" and slug("env") == "env")

envs, domains = ["dev", "prd"], ["claims", "profitability"]
check("a stack refuses a scope it does not support", any("does not support" in p for p in check_target("10-foundation", "dev", "domain:claims", envs, domains)))
check("a domain scope needs a known domain", any("unknown domain" in p for p in check_target("40-unity-catalog", "dev", "domain:nope", envs, domains)))
check("shared scope takes no environment", any("takes no environment" in p for p in check_target("20-identity", "dev", "shared", envs, domains)))
check("an unknown environment is refused", any("unknown environment" in p for p in check_target("10-foundation", "qa", "env", envs, domains)))
check("a valid target has no problems", check_target("40-unity-catalog", "prd", "domain:claims", envs, domains) == [])

ok, naming = evaluate(CONFIG)
if not ok:
    print(naming)
    sys.exit(1)
targets = all_targets(naming)
check("every target of every stack is enumerated", len(targets) > 40)
check("observability only targets the prod environment",
      {t.env for t in targets if t.stack == "70-observability"} == {naming["prod_env"]})
check("access stack has one target per environment", {t.env for t in targets if t.stack == "25-access"} == set(naming["env_keys"]))


# ---------------------------------------------------------------------------
print("scope check")


def fake_plan(items):
    """A saved-plan JSON with one created resource per (type, instance key)."""
    return {"resource_changes": [
        {"address": f'module.x.{rtype}.this["{key}"]', "mode": "managed", "type": rtype, "index": key, "change": {"actions": ["create"]}}
        for rtype, key in items
    ]}


t = Target("40-unity-catalog", "prd", "domain:claims")
good = fake_plan([("databricks_schema", "domain:prd:claims/product_loss"), ("databricks_catalog", "domain:prd:claims"),
                  ("databricks_entity_tag_assignment", "domain:prd:claims|piq_env"),
                  ("databricks_entity_tag_assignment", "domain:prd:claims/business_vault|piq_layer"),
                  ("databricks_grants", "domain:prd:claims")])
r = check_plan(good, t, naming)
check("a plan of the target's own resources passes", r.ok and r.checked == 5, str(r))
check("derived keys are attributed", not r.unattributed, str(r.unattributed))

other_domain = fake_plan([("databricks_schema", "domain:prd:profitability/product_loss_ratio")])
check("another domain's schema is refused", not check_plan(other_domain, t, naming).ok)
other_env = fake_plan([("databricks_catalog", "domain:dev:claims")])
check("the same domain in another environment is refused", not check_plan(other_env, t, naming).ok)
check("the environment's own catalog is refused from a domain run", not check_plan(fake_plan([("databricks_catalog", "vault:prd")]), t, naming).ok)
mixed = fake_plan([("databricks_schema", "domain:prd:claims/product_loss"), ("databricks_schema", "domain:prd:profitability/product_loss_ratio")])
res = check_plan(mixed, t, naming)
check("a plan that mixes owned and foreign resources is refused and names the foreign one",
      (not res.ok) and len(res.violations) == 1 and "profitability" in res.violations[0], str(res.violations))
check("singletons (no instance key) belong to the run", check_plan({"resource_changes": [
    {"address": "module.ws.databricks_workspace_conf.this[0]", "mode": "managed", "index": 0, "change": {"actions": ["update"]}}]}, t, naming).ok)
check("no-op and read changes are ignored", check_plan({"resource_changes": [
    {"address": "a", "mode": "managed", "index": "domain:prd:profitability/x", "change": {"actions": ["no-op"]}},
    {"address": "b", "mode": "data", "index": "domain:prd:profitability/x", "change": {"actions": ["read"]}}]}, t, naming).ok)
check("an unknown key is reported, not failed", check_plan(fake_plan([("random_thing", "mystery-key")]), t, naming).unattributed == ['module.x.random_thing.this["mystery-key"]'])

# The shared scope creates the test users and the Terraform identities' metastore-admin memberships.
shared_t = Target("20-identity", None, "shared")
test_user = sorted(naming["test_users"])[0]
identity = sorted(naming["terraform_identities"])[0]
shared_plan = fake_plan([("azuread_user", test_user), ("random_password", test_user), ("azuread_group_member", identity)])
res = check_plan(shared_plan, shared_t, naming)
check("test users and Terraform identities belong to the shared scope: no notes, no violations",
      res.ok and not res.unattributed and res.checked == 3, str((res.violations, res.unattributed)))
check("the same resources are refused from an environment's domain scope",
      not check_plan(shared_plan, Target("20-identity", "prd", "domain:claims"), naming).ok)
check("every Terraform identity is named by prefix and environment",
      sorted(naming["terraform_identities"]) == sorted([f"sp-{naming['prefix']}-terraform"] + [f"sp-{naming['prefix']}-terraform-{e}" for e in naming["env_keys"]]))

# Every scope's own items pass its own check, and mixing two scopes fails.
sample = [("dev", "env"), ("prd", "env"), ("prd", "domain:claims"), ("dev", "domain:profitability"), ("prd", "access"), (None, "shared")]
keysets = {}
for env, scope in sample:
    okk, out = evaluate(CONFIG, env, scope)
    items = []
    for name, rtype in (("groups", "azuread_group"), ("catalogs", "databricks_catalog"), ("schemas", "databricks_schema"),
                        ("service_principals", "azuread_service_principal"), ("usage_scopes", "databricks_budget_policy"),
                        ("abac_policies", "databricks_policy_info"), ("governed_tags", "databricks_tag_policy"),
                        ("access_user_memberships", "azuread_group_member"), ("nesting", "azuread_group_member")):
        items += [(rtype, k) for k in out[name]]
    items += [("databricks_sql_endpoint", name) for e, ws in out["warehouses"].items() for name in ws if e == env]
    keysets[(env, scope)] = items
    tt = Target("40-unity-catalog", env, scope)
    check(f"{tt.sid}: all of its own items pass the scope check", check_plan(fake_plan(items), tt, naming).ok,
          str(check_plan(fake_plan(items), tt, naming).violations[:2]))
a, b = ("prd", "domain:claims"), ("dev", "domain:profitability")
check("items of two scopes mixed are refused", not check_plan(fake_plan(keysets[a] + keysets[b]), Target("40-unity-catalog", *a), naming).ok)


# ---------------------------------------------------------------------------
print("promotion gate")
os.environ["PIQ_DEPLOY_STORE"] = "local"
tmp = pathlib.Path(tempfile.mkdtemp(prefix="deploys-"))
st = deploys.LocalStore(tmp)
env_cfg = naming["environments"]
prd = Target("40-unity-catalog", "prd", "domain:claims")
dev = Target("40-unity-catalog", "dev", "domain:claims")
REL = "rel-2026.10.23.1"

check("dev accepts any commit", deploys.check_promotion(st, dev, "sha:abc1234567", env_cfg) == [])
check("prod refuses a release that never reached dev", len(deploys.check_promotion(st, prd, REL, env_cfg)) == 1)
check("prod refuses a plain commit", any("only accepts a release tag" in p for p in deploys.check_promotion(st, prd, "sha:abc1234567", env_cfg)))
st.put(deploys.record(dev, REL, "a" * 40, "FAIL"))
check("a failed dev deploy does not count", len(deploys.check_promotion(st, prd, REL, env_cfg)) == 1)
st.put(deploys.record(dev, REL, "a" * 40, "PASS"))
check("a successful dev deploy lets the release go to prod", deploys.check_promotion(st, prd, REL, env_cfg) == [])
other_domain = Target("40-unity-catalog", "prd", "domain:profitability")
check("the gate is per domain: claims reaching dev says nothing about profitability", len(deploys.check_promotion(st, other_domain, REL, env_cfg)) == 1)
check("the gate is per release", len(deploys.check_promotion(st, prd, "rel-2026.10.24.1", env_cfg)) == 1)
check("a hotfix needs an approver", deploys.check_promotion(st, prd, "rel-2026.10.24.1", env_cfg, hotfix=True) == ["a hotfix deploy needs --approver <name>"])
check("a hotfix with an approver skips the gate where allowed",
      deploys.check_promotion(st, prd, "rel-2026.10.24.1", env_cfg, hotfix=True, approver="lead") == [])
check("a hotfix is refused where the environment does not allow it", any("does not allow hotfix" in p for p in
      deploys.check_promotion(st, dev, "rel-2026.10.24.1", env_cfg, hotfix=True, approver="lead")))
check("shared scope has nothing to promote through", deploys.check_promotion(st, Target("20-identity", None, "shared"), "sha:x", env_cfg) == [])
check("latest successful deploy is reported", (deploys.latest(st, "40-unity-catalog", "dev", "domain:claims") or {}).get("release") == REL)

graph = {"dev1": {"promotes_from": []}, "dev2": {"promotes_from": []},
         "qa": {"promotes_from": ["dev1", "dev2"]}, "prd": {"promotes_from": ["qa"], "allow_hotfix": True}}
qa = Target("40-unity-catalog", "qa", "domain:claims")
d1 = Target("40-unity-catalog", "dev1", "domain:claims")
d2 = Target("40-unity-catalog", "dev2", "domain:claims")
st.put(deploys.record(d1, REL, "a" * 40, "PASS"))
check("environments are a graph: qa needs BOTH dev1 and dev2", len(deploys.check_promotion(st, qa, REL, graph)) == 1)
st.put(deploys.record(d2, REL, "a" * 40, "PASS"))
check("qa accepts the release once both ran it", deploys.check_promotion(st, qa, REL, graph) == [])


# ---------------------------------------------------------------------------
print("reading deploy records from Azure storage (fake az)")
import json  # noqa: E402


class FakeAz(deploys.BlobStore):
    """Behaves like the az CLI where it matters: a download needs a real, seekable file, never a stream."""

    def __init__(self):
        super().__init__("fakeaccount")
        self.blobs = {}

    def _az(self, *args):
        a = list(args)
        if a[:3] == ["storage", "container", "create"]:
            return subprocess.CompletedProcess(a, 0, "", "")
        if a[:3] == ["storage", "blob", "upload"]:
            self.blobs[a[a.index("--name") + 1]] = pathlib.Path(a[a.index("--file") + 1]).read_text()
            return subprocess.CompletedProcess(a, 0, "", "")
        if a[:3] == ["storage", "blob", "list"]:
            prefix = a[a.index("--prefix") + 1]
            return subprocess.CompletedProcess(a, 0, json.dumps([n for n in self.blobs if n.startswith(prefix)]), "")
        if a[:3] == ["storage", "blob", "download"]:
            target = a[a.index("--file") + 1]
            if target.startswith("/dev/"):
                return subprocess.CompletedProcess(a, 1, "", "ValueError: Target stream handle must be seekable.")
            pathlib.Path(target).write_text(self.blobs[a[a.index("--name") + 1]])
            return subprocess.CompletedProcess(a, 0, "", "")
        raise AssertionError(f"unexpected az call: {a}")


fake = FakeAz()
rec_target = Target("40-unity-catalog", "dev", "domain:claims")
fake.put(deploys.record(rec_target, REL, "a" * 40, "PASS"))
got = fake.list(rec_target.stack, "dev", rec_target.scope)
check("a deploy record written to blob storage can be read back", len(got) == 1 and got[0]["release"] == REL, str(got))
check("the promotion gate works on records read from blob storage",
      deploys.check_promotion(fake, Target("40-unity-catalog", "prd", "domain:claims"), REL, env_cfg) == [])


# ---------------------------------------------------------------------------
print("releases")
check("release tags are recognised", release.is_release_tag("rel-2026.10.23.1") and not release.is_release_tag("v1.0") and not release.is_release_tag("rel-2026.10.23"))
check("next tag has the expected shape", release.is_release_tag(release.next_tag()))
check("describe_head gives a tag or a short sha", release.describe_head().startswith(("rel-", "sha:")))


# ---------------------------------------------------------------------------
print("apply.py safety rules")
run = lambda *a: subprocess.run([sys.executable, str(ROOT / "scripts" / "apply.py"), *a], capture_output=True, text=True)
r = run("40-unity-catalog", "--scope", "domain:claims", "--env", "dev", "--yes")
check("--yes without --plan is refused (exit 2)", r.returncode == 2 and "--yes needs --plan" in r.stderr, r.stderr)
r = run("10-foundation", "--scope", "domain:claims", "--env", "dev")
check("an unsupported scope is refused (exit 1)", r.returncode == 1 and "does not support" in r.stderr, r.stderr)
r = run("20-identity", "--scope", "shared", "--env", "dev")
check("shared with an environment is refused", r.returncode == 1 and "takes no environment" in r.stderr, r.stderr)
r = run("70-observability", "--scope", "env", "--env", "dev")
check("observability is refused outside the prod environment", r.returncode == 1 and "prod environment" in r.stderr, r.stderr)

print()
if failures:
    print(f"{len(failures)} FAILED")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("all wrapper tests passed")
