terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

# Azure Provider Configuration
# Disables automatic resource provider registration, which prevents permissions errors in CI/CD environments.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true # Required for deployment success in this environment
}

# --- Input Variables ---

# The name of the virtual machine instance.
variable "instance_name" {
  type    = string
  default = "test-winh"
  description = "The name of the virtual machine instance."
}

# The Azure region where resources will be deployed.
variable "region" {
  type    = string
  default = "East US"
  description = "The Azure region where resources will be deployed."
}

# The size (SKU) of the virtual machine.
variable "vm_size" {
  type    = string
  default = "Standard_B1s"
  description = "The size (SKU) of the virtual machine."
}

# The unique identifier for the tenant. Used for naming tenant-specific resources.
variable "tenant_id" {
  type    = string
  default = "tenant-manager-001"
  description = "The unique identifier for the tenant. Used for naming tenant-specific resources."
}

# The name of the existing Azure Resource Group.
variable "azure_resource_group" {
  type    = string
  default = "umos"
  description = "The name of the existing Azure Resource Group."
}

# The Azure Subscription ID where resources will be deployed.
variable "subscription_id" {
  type    = string
  default = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
  description = "The Azure Subscription ID where resources will be deployed."
}

# A custom script to be executed on the VM during provisioning (user data).
variable "custom_script" {
  type    = string
  default = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "A custom script to be executed on the VM during provisioning (user data)."
}

# --- Data Sources ---

# Look up the existing Azure Resource Group.
# This data source is used instead of creating a new resource group, as per instructions.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Data source to check for an existing Virtual Network (VNet) for the tenant.
# This implements the "get-or-create" pattern for the VNet.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Data source to check for an existing Network Security Group (NSG) for the tenant.
# This implements the "get-or-create" pattern for the NSG.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# --- Random Generators ---

# Generates a random password for the Windows Administrator account.
# Marked as sensitive in outputs.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# Generates a random octet for dynamic subnet addressing to prevent collisions.
# Ensures each deployment gets a unique /24 subnet within the tenant's VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# --- Locals Block for Conditional Resource Selection ---

locals {
  # Selects the VNet ID: existing if found, otherwise the newly created one.
  vnet_id = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  # Selects the VNet Name: existing if found, otherwise the newly created one.
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name

  # Selects the NSG ID: existing if found, otherwise the newly created one.
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# --- Networking Resources ---

# Conditionally creates a Virtual Network (VNet) for the tenant if one doesn't already exist.
# The 'count' meta-argument implements the "get-or-create" logic.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Creates a new, dynamically addressed subnet within the tenant's VNet.
# The random octet ensures uniqueness and prevents address space collisions for new deployments.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Conditionally creates a Network Security Group (NSG) for the tenant if one doesn't already exist.
# Includes a security rule to allow SSH from Azure's infrastructure for management agents.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                         = "AllowSSH_from_AzureCloud"
    priority                     = 1001
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "22" # As per critical instructions
    source_address_prefix        = "AzureCloud"
    destination_address_prefix   = "*"
  }
}

# Associates the dynamically created subnet with the tenant's Network Security Group.
# This is the mandated way to associate the NSG, not directly on the NIC.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Creates a Standard SKU Public IP address for the VM.
# Standard SKU and Static allocation are required for robust deployments.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Creates a Network Interface for the VM.
# It is associated with the dynamically created subnet and the public IP.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }
  # CRITICAL: network_security_group_id is FORBIDDEN here.
  # NSG association is done via azurerm_subnet_network_security_group_association.
}

# --- Virtual Machine Resource ---

# Deploys the Windows Virtual Machine.
# Uses the custom image ID and sets administrator password and user data.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser"
  admin_password      = random_password.admin_password.result
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # OS Disk Configuration
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Custom Image Source
  # Uses the exact custom image name provided in the critical instructions.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-19363652771"

  # Custom data (user data) for post-deployment configuration.
  # The script is base64 encoded for Azure.
  custom_data = base64encode(var.custom_script)

  # Enables boot diagnostics for serial console access.
  boot_diagnostics {}

  # CRITICAL: The 'enabled' argument is FORBIDDEN for this resource type.
}

# --- Outputs ---

# Exposes the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Exposes the generated administrator password for the Windows VM.
# Marked as sensitive to prevent plain-text logging.
output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}