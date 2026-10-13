# Template: domain repo (Asset Bundle + dbt)

Copy this folder to start a producer domain repo (for example `piq-claims`).
It deploys the domain's pipelines to dev and prd with the same code: the only
thing that differs per target is `env`, from which every catalog name is built.

```
databricks.yml            bundle: targets dev/prd, variables, run-as deployer
resources/dbt_job.yml     Lakeflow job running dbt on the domain warehouse
dbt/dbt_project.yml       dbt project; schemas map to the domain's layers
dbt/profiles.yml          local runs only; on Databricks the dbt task sets the catalog
dbt/models/sources.yml    vault and other products, catalog from the env
dbt/models/products/...   product models land in product_<name> schemas
```

Rules the template enforces:
- **No environment in code.** `env` comes from the bundle target; the dbt task
  sets `catalog = {env}_{domain}`, sources use `target.name`; SQL and notebooks
  take `env` as a parameter.
- **Products read products.** A derived product (e.g. profitability) declares
  other domains' product schemas as sources, never their private schemas.
- **Run as the deployer.** Jobs run as `sp-piq-<env>-<domain>-deploy`, on
  `piq-<domain>-transform`. CI authenticates with GitHub OIDC; no tokens.
- **Promotion is a config change.** Point a model's schema at
  `product_<name>` (and add the product to `config/products/<domain>.yaml` in
  the platform repo). No data is moved.

```bash
databricks bundle validate -t dev
databricks bundle deploy -t dev
databricks bundle run dbt_build -t dev
```
