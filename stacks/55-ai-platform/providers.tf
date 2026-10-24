terraform {
  required_version = ">= 1.6.0"
  required_providers {
    databricks = { source = "databricks/databricks", version = "~> 1.137" }
  }
  backend "azurerm" {} # key = 55-ai-platform/<env>/<scope>.tfstate, set by scripts/tf.sh
}

# One run uses one workspace: the environment's.
provider "databricks" {
  host      = data.terraform_remote_state.foundation.outputs.workspaces[var.environment].url
  auth_type = "azure-cli"
}
