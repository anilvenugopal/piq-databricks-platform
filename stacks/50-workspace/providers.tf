terraform {
  required_version = ">= 1.6.0"
  required_providers {
    databricks = { source = "databricks/databricks", version = "~> 1.137" }
  }
  backend "azurerm" {} # key = 50-workspace.tfstate
}

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
