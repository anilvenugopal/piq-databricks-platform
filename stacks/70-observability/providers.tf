terraform {
  required_version = ">= 1.6.0"
  backend "azurerm" {} # key = 70-observability.tfstate
}
