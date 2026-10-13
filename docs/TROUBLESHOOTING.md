# Troubleshooting

This repo has not been applied to a live account yet. These are the problems most
likely on a first run, with the fix for each.

| Symptom | Likely cause | Fix |
|---|---|---|
| Bootstrap: `Authorization_RequestDenied` on app role assignment | You are not Global Admin / Privileged Role Admin | Run bootstrap as a Global Administrator |
| 10-foundation: storage account name taken | `unique_suffix` collides globally | Change `unique_suffix` in `platform.yaml` |
| 10-foundation: Key Vault name in use | Soft-deleted vault from a teardown | `az keyvault purge --name <name>` (dev) or wait out retention |
| 30-account: `external-groups ... not onboarded onto AIM` | Automatic identity management off | Account console → Settings → enable it (Phase 4 step 3) |
| 30-account: 403 on any call | Terraform SP is not account admin | Phase 4 step 4 |
| 30-account: external user not found | UPN in sandbox/experiments not in Entra | Fix the UPN; apply 20 before 30 |
| 40: `PERMISSION_DENIED: CREATE STORAGE CREDENTIAL` | Metastore admin not set to `piq-metastore-admins` | Phase 4 step 6; wait a few minutes for group sync |
| 40: workspace binding already exists | ISOLATED catalogs auto-bind their creating workspace | Remove the `databricks_workspace_binding` resource for same-workspace bindings, or `terraform import` it |
| 40: tag assignment fails "value not allowed" | Value missing from `governed_tags.yaml` | Add it, apply 40 |
| 40: grant to a group fails "principal does not exist" | Group not yet resolved into the account | Apply 30 first; it provisions groups via AIM |
| 50: `databricks_system_schema` error "already enabled" | Schema enabled by default in your account | Remove it from `system_schemas` in `stacks/50-workspace/main.tf` |
| 50: warehouse creation slow | Normal on first serverless warehouse | Wait; timeout is 20 minutes by default |
| 60: `run_sql.py` ModuleNotFoundError | Runner lacks the SDK | `pip install -r requirements.txt` |
| 60: policy create fails on function | Function not created yet or wrong catalog | Check `SHOW FUNCTIONS IN <env>_platform.governance`; re-run apply |
| Classic cluster stuck "Pending" | No outbound internet without NAT | Set `nat_gateway: true` for that env, apply 10, or use serverless |
| CI blocked after enabling IP lists | GitHub-hosted runner IPs not allowed | Empty `ip_access_list`, or use self-hosted runners in an allowed range |
| Masking does not apply | Column tagged on the table, not the column; or user is in an exempt group | Tag the column itself; check group nesting |

## Useful commands

```bash
az account show                                   # which identity Terraform will use
./scripts/tf.sh 40-unity-catalog state list | head
./scripts/tf.sh 30-account plan -target='databricks_mws_permission_assignment.group'
databricks auth describe --host <workspace-url>   # Databricks CLI identity check
```
