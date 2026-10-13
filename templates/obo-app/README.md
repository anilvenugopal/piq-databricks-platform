# Template: on-behalf-of-user (OBO) Databricks App

Copy this folder into a domain repo to start an app that queries governed data
**as the signed-in user**, so Unity Catalog grants, row filters and ABAC masks
apply to the person, not to the app.

Why OBO is the default: every app has its own service principal. If that SP
could read unmasked data, every user of the app would see unmasked data. With
OBO, the app forwards the user's token and Unity Catalog enforces that user's
permissions. Use the app's own SP only for state the app owns (for example its
Lakebase tables).

```bash
databricks bundle validate -t dev
databricks bundle deploy -t dev
databricks bundle run claims_explorer -t dev
```

The bundle declares the SQL warehouse as an app resource; deploying grants the
app's SP `CAN_USE` on it automatically. `user_api_scopes: [sql]` is the only
scope the app may use on the user's behalf.
