terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# The subscription comes from the environment (ARM_SUBSCRIPTION_ID) or `az login`.
provider "azurerm" {
  features {}
}
