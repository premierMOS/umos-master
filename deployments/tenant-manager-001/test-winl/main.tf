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

# Configure the AzureRM Provider
# CRITICAL: Disables automatic resource provider registration as required by deployment environment.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# Terraform variables for key configuration values, with defaults directly from the JSON.
# This prevents interactive prompts during `terraform plan` or `terraform apply`.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-winl"
}

variable "region" {
  description = "The Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size/SKU of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for resource naming and isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "os_image_name" {
  description = "The name of the custom OS image to use for the VM."
  type        = string
  default     = "windows-2019-19363652771"
}

variable "custom_script" {
  description = "A custom script to be executed on the VM upon startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# CRITICAL: Random password generation for Windows administrator account.
# This ensures a strong, unique password for each deployment.
resource "random_password" "admin_password" {
  length          = 16
  special         = true
  override_special = "_!@#&" # Specific special characters as required
}

# CRITICAL: Data source to reference the existing Azure Resource Group.
# This resource group is assumed to already exist and will not be created by Terraform.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Data source to check for an existing Virtual Network (VNet) for the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  # CRITICAL ANTI-CYCLE INSTRUCTION: No 'local' variables referenced here.
}

# Conditionally create a new Virtual Network (VNet) if it does not already exist.
# The 'count' meta-argument implements the "get-or-create" pattern.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space
}

# Data source to check for an existing Network Security Group (NSG) for the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
  # CRITICAL ANTI-CYCLE INSTRUCTION: No 'local' variables referenced here.
}

# Conditionally create a new Network Security Group (NSG) if it does not already exist.
# The 'count' meta-argument implements the "get-or-create" pattern.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL: Security rule to allow SSH (port 22) from Azure's infrastructure.
  # Although for Windows, RDP (3389) is more common, instruction explicitly states port 22.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "AzureCloud"
    destination_address_prefix = "*"
  }
}

# Locals block to select the correct VNet and NSG attributes (ID and name)
# based on whether they were newly created or found existing.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Random integer to generate a unique subnet octet, preventing address conflicts.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Create a new, non-overlapping subnet for this specific deployment.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # CRITICAL: Dynamically assigns a /24 subnet within the VNet's address space.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Associate the newly created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL NETWORKING REQUIREMENT: Create a Standard SKU Public IP address.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL AZURE IP SKU
}

# Create the Network Interface for the Virtual Machine.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.this_subnet.id # CRITICAL: Subnet from dynamic creation
    public_ip_address_id          = azurerm_public_ip.this_pip.id  # Associates public IP
  }
  # CRITICAL NIC/NSG ASSOCIATION RULE: network_security_group_id is FORBIDDEN here.
  # NSG association is done via azurerm_subnet_network_security_group_association.
}

# Main Virtual Machine resource. Named "this_vm" as required.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser"
  # CRITICAL WINDOWS PASSWORD: Set admin password from the random_password resource.
  admin_password      = random_password.admin_password.result
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # CRITICAL IMAGE NAME INSTRUCTION: Using the specific custom image ID format.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # CRITICAL: Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # CRITICAL USER DATA/CUSTOM SCRIPT: Pass custom script as base64 encoded custom_data.
  custom_data = base64encode(var.custom_script)

  # CRITICAL AZURE VM ARGUMENT INSTRUCTION: 'enabled' argument is not supported here.
}

# Output block to expose the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output block to expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# CRITICAL WINDOWS PASSWORD OUTPUT: Exposes the generated administrator password.
# Marked as sensitive to prevent it from being displayed in plain text in logs.
output "admin_password" {
  description = "The generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}