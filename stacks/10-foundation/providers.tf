terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
  }
  backend "azurerm" {} # configured by scripts/tf.sh (key = 10-foundation.tfstate)
}

locals {
  platform_cfg = yamldecode(file("${path.root}/../../config/platform.yaml"))
}

provider "azurerm" {
  features {
    key_vault { purge_soft_delete_on_destroy = false }
  }
  subscription_id     = local.platform_cfg.azure.subscription_id
  tenant_id           = local.platform_cfg.azure.tenant_id
  storage_use_azuread = true
}
