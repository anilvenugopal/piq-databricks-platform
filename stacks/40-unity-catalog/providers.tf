terraform {
  required_version = ">= 1.6.0"
  required_providers {
    databricks = { source = "databricks/databricks", version = "~> 1.137" }
  }
  backend "azurerm" {} # key = 40-unity-catalog.tfstate
}

locals {
  platform_cfg = yamldecode(file("${path.root}/../../config/platform.yaml"))
}

provider "databricks" {
  alias      = "account"
  host       = local.platform_cfg.databricks.account_host
  account_id = local.platform_cfg.databricks.account_id
  auth_type  = "azure-cli"
}

# Workspace-level providers. Unity Catalog APIs are workspace-scoped; which
# workspace you call through determines the binding of ISOLATED objects.
provider "databricks" {
  alias     = "dev"
  host      = data.terraform_remote_state.foundation.outputs.workspaces["dev"].url
  auth_type = "azure-cli"
}

provider "databricks" {
  alias     = "prd"
  host      = data.terraform_remote_state.foundation.outputs.workspaces["prd"].url
  auth_type = "azure-cli"
}
