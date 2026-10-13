# bootstrap

One-time stack, run locally by a human who is **Owner** on the subscription and
**Global Administrator** (or Privileged Role Administrator) in Entra ID.

```bash
az login --tenant <tenant-id>
cd bootstrap
terraform init
terraform plan -out tfplan     # read it
terraform apply tfplan
terraform output github_variables
```

What it creates and why is explained in `docs/RUNBOOK.md` Phase 2 and in the
learning guide section "Terraform for Databricks". After this stack, nothing is
applied from a laptop again: every change goes through a pull request.

`terraform.tfstate` in this folder is git-ignored. Back it up, or migrate it into
the remote state container with `terraform init -migrate-state` after adding an
`azurerm` backend block (instructions in the runbook).
