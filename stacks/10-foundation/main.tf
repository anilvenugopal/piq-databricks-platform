# =============================================================================
# 10-foundation - Azure resources per environment.
#
#   rg-<prefix>-<env>                 resource group
#   vnet-<prefix>-<env>               VNet with two delegated subnets (VNet injection)
#   dbw-<prefix>-<env>                Azure Databricks workspace, Premium, no public IPs
#   st<prefix><env><suffix>           ADLS Gen2 account; one container per catalog
#   ac-<prefix>-<env>                 Access Connector (managed identity) for Unity Catalog
#   kv-<prefix>-<env>-<suffix>        Key Vault for secrets that cannot use OIDC
#
# Creating the FIRST Premium workspace creates the Databricks account itself.
# =============================================================================

module "naming" {
  source     = "../../modules/naming"
  config_dir = "${path.root}/../../config"
}

locals {
  p      = module.naming.platform
  prefix = module.naming.prefix
  envs   = module.naming.environments
  sfx    = local.p.unique_suffix

  # One container per catalog (vault, domains, consumer prep, anonymized, platform, sandbox).
  containers = { for item in flatten([
    for env, names in module.naming.storage_containers : [for n in names : { env = env, name = n }]
  ]) : "${item.env}-${item.name}" => item }

  nat_envs = { for env, cfg in local.envs : env => cfg if try(cfg.network.nat_gateway, false) }

  base_tags = { managed_by = "terraform", platform = local.prefix }
  env_tags  = { for env in keys(local.envs) : env => merge(local.base_tags, { piq_env = env }) }
}

resource "azurerm_resource_group" "env" {
  for_each = local.envs
  name     = "rg-${local.prefix}-${each.key}"
  location = local.p.azure.location
  tags     = local.env_tags[each.key]
}

# -----------------------------------------------------------------------------
# Networking: VNet injection + secure cluster connectivity (no public IPs).
# Classic cluster nodes live in YOUR VNet; serverless compute does not.
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "env" {
  for_each            = local.envs
  name                = "vnet-${local.prefix}-${each.key}"
  location            = azurerm_resource_group.env[each.key].location
  resource_group_name = azurerm_resource_group.env[each.key].name
  address_space       = [each.value.network.vnet_cidr]
  tags                = local.env_tags[each.key]
}

resource "azurerm_network_security_group" "env" {
  for_each            = local.envs
  name                = "nsg-${local.prefix}-${each.key}-dbw"
  location            = azurerm_resource_group.env[each.key].location
  resource_group_name = azurerm_resource_group.env[each.key].name
  tags                = local.env_tags[each.key]
  # Rules are added and maintained by Azure Databricks (network_security_group_rules_required).
}

locals {
  subnets = merge(
    { for env, cfg in local.envs : "${env}-host" => { env = env, kind = "host", cidr = cfg.network.host_subnet_cidr } },
    { for env, cfg in local.envs : "${env}-container" => { env = env, kind = "container", cidr = cfg.network.container_subnet_cidr } },
  )
}

resource "azurerm_subnet" "dbw" {
  for_each             = local.subnets
  name                 = "snet-${local.prefix}-${each.value.env}-${each.value.kind}"
  resource_group_name  = azurerm_resource_group.env[each.value.env].name
  virtual_network_name = azurerm_virtual_network.env[each.value.env].name
  address_prefixes     = [each.value.cidr]

  delegation {
    name = "databricks"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "dbw" {
  for_each                  = local.subnets
  subnet_id                 = azurerm_subnet.dbw[each.key].id
  network_security_group_id = azurerm_network_security_group.env[each.value.env].id
}

# Optional NAT gateway: gives classic clusters outbound internet access.
resource "azurerm_public_ip" "nat" {
  for_each            = local.nat_envs
  name                = "pip-${local.prefix}-${each.key}-nat"
  location            = azurerm_resource_group.env[each.key].location
  resource_group_name = azurerm_resource_group.env[each.key].name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.env_tags[each.key]
}

resource "azurerm_nat_gateway" "env" {
  for_each            = local.nat_envs
  name                = "ng-${local.prefix}-${each.key}"
  location            = azurerm_resource_group.env[each.key].location
  resource_group_name = azurerm_resource_group.env[each.key].name
  sku_name            = "Standard"
  tags                = local.env_tags[each.key]
}

resource "azurerm_nat_gateway_public_ip_association" "env" {
  for_each             = local.nat_envs
  nat_gateway_id       = azurerm_nat_gateway.env[each.key].id
  public_ip_address_id = azurerm_public_ip.nat[each.key].id
}

resource "azurerm_subnet_nat_gateway_association" "dbw" {
  for_each       = { for k, s in local.subnets : k => s if contains(keys(local.nat_envs), s.env) }
  subnet_id      = azurerm_subnet.dbw[each.key].id
  nat_gateway_id = azurerm_nat_gateway.env[each.value.env].id
}

# -----------------------------------------------------------------------------
# Workspaces
# -----------------------------------------------------------------------------
resource "azurerm_databricks_workspace" "env" {
  for_each                              = local.envs
  name                                  = "dbw-${local.prefix}-${each.key}"
  location                              = azurerm_resource_group.env[each.key].location
  resource_group_name                   = azurerm_resource_group.env[each.key].name
  managed_resource_group_name           = "rg-${local.prefix}-${each.key}-dbw-managed"
  sku                                   = "premium"
  public_network_access_enabled         = true # front-end Private Link is a later hardening step
  network_security_group_rules_required = "AllRules"

  custom_parameters {
    no_public_ip                                         = true
    virtual_network_id                                   = azurerm_virtual_network.env[each.key].id
    public_subnet_name                                   = azurerm_subnet.dbw["${each.key}-host"].name
    private_subnet_name                                  = azurerm_subnet.dbw["${each.key}-container"].name
    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.dbw["${each.key}-host"].id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.dbw["${each.key}-container"].id
  }

  tags = local.env_tags[each.key]
}

# -----------------------------------------------------------------------------
# Storage for Unity Catalog managed tables and volumes
# -----------------------------------------------------------------------------
resource "azurerm_storage_account" "lake" {
  for_each                        = local.envs
  name                            = substr("st${local.prefix}${each.key}lake${local.sfx}", 0, 24)
  resource_group_name             = azurerm_resource_group.env[each.key].name
  location                        = azurerm_resource_group.env[each.key].location
  account_tier                    = "Standard"
  account_replication_type        = each.value.storage_replication
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true # ADLS Gen2 hierarchical namespace
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false # identities only: access connector, Terraform SP
  allow_nested_items_to_be_public = false

  blob_properties {
    delete_retention_policy { days = each.key == "prd" ? 30 : 7 }
    container_delete_retention_policy { days = each.key == "prd" ? 30 : 7 }
  }
  tags = local.env_tags[each.key]
}

resource "azurerm_storage_container" "catalog" {
  for_each              = local.containers
  name                  = each.value.name
  storage_account_id    = azurerm_storage_account.lake[each.value.env].id
  container_access_type = "private"
}

# The access connector is the Azure identity Unity Catalog uses to touch storage.
# Users never get storage permissions; UC vends short-lived credentials instead.
resource "azurerm_databricks_access_connector" "env" {
  for_each            = local.envs
  name                = "ac-${local.prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.env[each.key].name
  location            = azurerm_resource_group.env[each.key].location
  identity { type = "SystemAssigned" }
  tags = local.env_tags[each.key]
}

resource "azurerm_role_assignment" "ac_blob" {
  for_each             = local.envs
  scope                = azurerm_storage_account.lake[each.key].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.env[each.key].identity[0].principal_id
}

# Needed for Auto Loader / managed file events (queue-based file discovery).
resource "azurerm_role_assignment" "ac_queue" {
  for_each             = local.envs
  scope                = azurerm_storage_account.lake[each.key].id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_databricks_access_connector.env[each.key].identity[0].principal_id
}

# -----------------------------------------------------------------------------
# Key Vault (for the few secrets that cannot be replaced by OIDC federation)
# -----------------------------------------------------------------------------
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "env" {
  for_each                   = local.envs
  name                       = substr("kv-${local.prefix}-${each.key}-${local.sfx}", 0, 24)
  location                   = azurerm_resource_group.env[each.key].location
  resource_group_name        = azurerm_resource_group.env[each.key].name
  tenant_id                  = local.p.azure.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = each.key == "prd"
  soft_delete_retention_days = each.key == "prd" ? 90 : 7
  tags                       = local.env_tags[each.key]
}

# -----------------------------------------------------------------------------
# Outputs consumed by later stacks through terraform_remote_state
# -----------------------------------------------------------------------------
output "workspaces" {
  value = { for env, w in azurerm_databricks_workspace.env : env => {
    resource_id  = w.id
    workspace_id = w.workspace_id
    url          = "https://${w.workspace_url}"
    rg           = azurerm_resource_group.env[env].name
  } }
}

output "storage" {
  value = { for env, s in azurerm_storage_account.lake : env => {
    name         = s.name
    id           = s.id
    dfs_endpoint = s.primary_dfs_endpoint
  } }
}

output "access_connectors" {
  value = { for env, a in azurerm_databricks_access_connector.env : env => a.id }
}

output "key_vaults" {
  value = { for env, k in azurerm_key_vault.env : env => { id = k.id, uri = k.vault_uri } }
}
