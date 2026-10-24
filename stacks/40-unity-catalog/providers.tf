terraform {
  required_version = ">= 1.6.0"
  required_providers {
    databricks = { source = "databricks/databricks", version = "~> 1.137" }
  }
  backend "azurerm" {} # key = 40-unity-catalog/<shared|<env>/<scope>>.tfstate, set by scripts/tf.sh
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

# Workspace-level provider. Unity Catalog APIs are workspace-scoped; which workspace you
# call through determines the binding of ISOLATED objects. One run uses one workspace.
provider "databricks" {
  host      = data.terraform_remote_state.foundation.outputs.workspaces[local.home_env].url
  auth_type = "azure-cli"
}
