"""
Derives expected infrastructure names from config/ using the same rules
as modules/naming/main.tf. Used by per-stack checks so they stay correct
when config changes — no hardcoded names anywhere.
"""
import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
CFG = ROOT / "config"


def _load(rel: str) -> dict:
    p = CFG / rel
    return (yaml.safe_load(p.read_text()) or {}) if p.exists() else {}


class Config:
    def __init__(self):
        self._platform = _load("platform.yaml")
        self._domains_cfg = _load("domains.yaml")
        self._personas = _load("personas.yaml")
        self._sars = _load("sars.yaml")
        self._matrix = _load("access_matrix.yaml")
        self._consumers = {
            p.stem: (yaml.safe_load(p.read_text()) or {})
            for p in sorted((CFG / "consumers").glob("*.yaml"))
        }
        products_raw = {}
        for p in sorted((CFG / "products").glob("*.yaml")):
            for name, cfg in ((yaml.safe_load(p.read_text()) or {}).get("products") or {}).items():
                products_raw[name] = {**cfg, "domain": p.stem}
        self._products = products_raw

    @property
    def prefix(self) -> str:
        return self._platform["prefix"]

    @property
    def envs(self) -> list[str]:
        return list(self._platform.get("environments", {}).keys())

    @property
    def domains(self) -> list[str]:
        return list(self._domains_cfg.get("domains", {}).keys())

    @property
    def roles(self) -> list[str]:
        return self._matrix.get("roles", [])

    @property
    def platform_groups(self) -> list[str]:
        return list(self._personas.get("platform_groups", {}).keys())

    @property
    def persona_keys(self) -> list[str]:
        return list(self._personas.get("personas", {}).keys())

    @property
    def sar_keys(self) -> list[str]:
        return list(self._sars.get("sars", {}).keys())

    @property
    def consumer_keys(self) -> list[str]:
        return list(self._consumers.keys())

    @property
    def products(self) -> dict:
        return self._products

    def expected_workspace_names(self) -> dict[str, str]:
        """env -> Databricks workspace resource name"""
        return {env: f"dbw-{self.prefix}-{env}" for env in self.envs}

    def expected_resource_groups(self) -> dict[str, str]:
        """env -> Azure resource group name"""
        return {env: f"rg-{self.prefix}-{env}" for env in self.envs}

    def expected_group_names(self) -> set[str]:
        """Full set of Entra group display names the naming module produces."""
        p = self.prefix
        names: set[str] = set()

        for env in self.envs:
            for domain in self.domains:
                for role in self.roles:
                    names.add(f"{p}-{env}-{domain.replace('_', '-')}-{role}")
                names.add(f"{p}-{env}-{domain.replace('_', '-')}-writer")
            names.add(f"{p}-{env}-vault-engineer")
            names.add(f"{p}-{env}-vault-writer")
            for sk in self.sar_keys:
                names.add(f"{p}-{env}-sar-{sk.replace('_', '-')}")
            for pname in self._products:
                names.add(f"{p}-{env}-product-{pname.replace('_', '-')}")

        for pg in self.platform_groups:
            names.add(f"{p}-{pg}")

        for pk in self.persona_keys:
            names.add(f"{p}-persona-{pk.replace('-', '-')}")

        for ck, ccfg in self._consumers.items():
            for role in ccfg.get("roles", []):
                names.add(f"{p}-prd-{ck.replace('_', '-')}-{role}")

        return names

    def expected_catalog_names(self) -> set[str]:
        """Catalog names the naming module produces."""
        cats: set[str] = set()
        for env in self.envs:
            for domain in self.domains:
                cats.add(f"{env}_{domain}")
            cats.add(f"{env}_vault")
            cats.add(f"{env}_platform")
            cats.add(f"{env}_sandbox")
        for ck in self.consumer_keys:
            cats.add(f"prd_{ck}")
        for domain, cfg in self._domains_cfg.get("domains", {}).items():
            if cfg.get("anon", False):
                cats.add(f"prd_{domain}_anon")
        return cats

    def expected_warehouse_names(self) -> dict[str, set[str]]:
        """env -> set of SQL warehouse display names expected in that workspace."""
        p = self.prefix
        result: dict[str, set[str]] = {}
        for env in self.envs:
            names: set[str] = set()
            for domain in self.domains:
                names.add(f"{p}-{domain.replace('_', '-')}-transform")
            names.add(f"{p}-vault-load")
            names.add(f"{p}-shared")
            result[env] = names
        for ck in self.consumer_keys:
            result["prd"].add(f"{p}-{ck.replace('_', '-')}-bi")
        return result
