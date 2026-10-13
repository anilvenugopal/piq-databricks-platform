terraform {
  required_version = ">= 1.6.0"
  required_providers {
    databricks = { source = "databricks/databricks", version = "~> 1.137" }
  }
  backend "azurerm" {} # key = 30-account.tfstate
}

locals {
  platform_cfg = yamldecode(file("${path.root}/../../config/platform.yaml"))
}

# Account-level provider. Auth: the Azure CLI session (az login locally,
# azure/login with OIDC in GitHub Actions) of the Terraform SP, which must be a
# Databricks ACCOUNT ADMIN (RUNBOOK Phase 4).
provider "databricks" {
  host       = local.platform_cfg.databricks.account_host
  account_id = local.platform_cfg.databricks.account_id
  auth_type  = "azure-cli"
}
