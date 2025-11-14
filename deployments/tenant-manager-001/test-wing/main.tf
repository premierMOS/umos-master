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
# CRITICAL: Disabling automatic provider registration as per instructions
provider "azurerm" {
  features {}
  subscription_id          = var.subscription_id
  skip_provider_registration = true
}

# --- Input Variables ---

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-wing"
}

variable "region" {
  description = "Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "Size of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used in resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "Custom script to run on VM startup. For Azure, this is passed as custom_data (base64 encoded)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "subscription_id" {
  description = "Azure Subscription ID for resource deployment."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "azure_resource_group_name" {
  description = "Name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

# --- Data Sources ---

# CRITICAL AZURE RESOURCE GROUP INSTRUCTION:
# Look up the existing Azure Resource Group. DO NOT create it.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Look for an existing Tenant Virtual Network.
# CRITICAL ANTI-CYCLE INSTRUCTION: Arguments must be directly from variables or other data sources.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Look for an existing Tenant Network Security Group.
# CRITICAL ANTI-CYCLE INSTRUCTION: Arguments must be directly from variables or other data sources.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# --- Resources ---

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS:
# Generate a random password for the VM's administrator.
resource "random_password" "admin_password" {
  length          = 16
  special         = true
  override_special = "_!@#&" # Specific override for special characters
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Conditionally create the Tenant Virtual Network if it doesn't exist.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space for the VNet
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Conditionally create the Tenant Network Security Group if it doesn't exist.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH from Azure's infrastructure.
  # CRITICAL: Specific rule as per instructions.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # As specified in instructions, even for Windows.
    source_address_prefix      = "AzureCloud"
    destination_address_prefix = "*"
  }
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Random integer to create a dynamic and unique subnet address.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Create a new, non-overlapping subnet for this deployment within the tenant VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # CRITICAL: Dynamic /24 subnet address using the random octet.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# CRITICAL NETWORKING REQUIREMENT:
# Create a Standard SKU Public IP address for the VM.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL AZURE IP SKU: Must be Standard.
}

# Create a Network Interface for the VM.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id # Associate public IP
  }
  # CRITICAL NIC/NSG ASSOCIATION RULE: network_security_group_id is FORBIDDEN here.
  # NSG association is done via 'azurerm_subnet_network_security_group_association'.
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Associate the dynamically created subnet with the tenant's NSG.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL IMAGE NAME INSTRUCTION:
# Deploy a Windows Virtual Machine using the specified custom image.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser" # Standard admin username for Azure Windows VMs
  # CRITICAL WINDOWS PASSWORD INSTRUCTIONS: Set admin password from generated random password.
  admin_password      = random_password.admin_password.result
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128 # Default disk size, can be variable if needed
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Use the exact custom image ID.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-19363652771"

  # USER DATA/CUSTOM SCRIPT: Pass custom_script as base64 encoded custom_data.
  custom_data = base64encode(var.custom_script)

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
  # Enable Boot Diagnostics for serial console access.
  boot_diagnostics {}

  # CRITICAL AZURE VM ARGUMENT INSTRUCTION: 'enabled' argument is FORBIDDEN here.
}

# --- Locals Block ---

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Local variables to select the correct VNet and NSG IDs based on whether they were found or created.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# --- Output Blocks ---

# Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The ID of the virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS: Output the generated administrator password.
output "admin_password" {
  description = "The generated administrator password for the VM."
  value       = random_password.admin_password.result
  sensitive   = true # Mark as sensitive to prevent plain-text logging.
}