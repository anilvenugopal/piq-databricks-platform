terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
  }
  backend "azurerm" {} # key = 25-access/<env>/access.tfstate, set by scripts/tf.sh
}

locals {
  platform_cfg = yamldecode(file("${path.root}/../../config/platform.yaml"))
}

provider "azuread" {
  tenant_id = local.platform_cfg.azure.tenant_id
}
