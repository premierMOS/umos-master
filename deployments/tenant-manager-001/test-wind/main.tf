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

# Configure the Microsoft Azure Provider
# CRITICAL AZURE PROVIDER CONFIGURATION:
# Disable automatic resource provider registration as per critical instructions,
# and specify the subscription ID.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# Declare Terraform variables for key configuration values from the JSON.
# Every variable declaration includes a 'default' value from the provided configuration.
variable "instance_name" {
  type        = string
  default     = "test-wind"
  description = "Name of the virtual machine instance."
}

variable "region" {
  type        = string
  default     = "East US"
  description = "Azure region where resources will be deployed."
}

variable "vm_size" {
  type        = string
  default     = "Standard_B1s"
  description = "Size of the virtual machine."
}

variable "tenant_id" {
  type        = string
  default     = "tenant-manager-001"
  description = "Identifier for the tenant, used for resource naming and isolation."
}

variable "custom_script" {
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to be executed on the VM during provisioning."
}

variable "resource_group_name" {
  type        = string
  default     = "umos"
  description = "Name of the existing Azure Resource Group."
}

variable "subscription_id" {
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
  description = "Azure Subscription ID for resource deployment."
}

# CRITICAL AZURE RESOURCE GROUP INSTRUCTION:
# Look up the existing Azure Resource Group. You are FORBIDDEN from creating a new one.
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS:
# Generate a random password for the administrator account of the Windows VM.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Look for an existing Virtual Network for this tenant.
# CRITICAL ANTI-CYCLE INSTRUCTION: No 'local' variables referenced here.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Look for an existing Network Security Group for this tenant.
# CRITICAL ANTI-CYCLE INSTRUCTION: No 'local' variables referenced here.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Locals block to select the correct VNet and NSG attributes based on existence.
# Using try() to gracefully handle cases where data sources do not find a resource.
locals {
  # Determine if VNet already exists. `try(..., null) != null` checks if the 'id' attribute was successfully retrieved.
  vnet_exists = try(data.azurerm_virtual_network.existing_vnet.id, null) != null
  vnet_id     = local.vnet_exists ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name   = local.vnet_exists ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name

  # Determine if NSG already exists.
  nsg_exists  = try(data.azurerm_network_security_group.existing_nsg.id, null) != null
  nsg_id      = local.nsg_exists ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Conditionally create the Virtual Network ONLY if the lookup failed.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = local.vnet_exists ? 0 : 1 # Use count for get-or-create pattern
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"]
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Conditionally create the Network Security Group ONLY if the lookup failed.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = local.nsg_exists ? 0 : 1 # Use count for get-or-create pattern
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH from Azure's infrastructure as per instructions.
  # Although for a Windows VM, RDP (3389) is more common, the instruction explicitly states SSH (22).
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

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Generate a random integer for dynamic subnet creation to prevent address space collisions.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Create a NEW, non-overlapping subnet for THIS deployment.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name # Associate with the selected VNet
  # CRITICAL INSTRUCTION: Dynamic /24 subnet address.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Associate the newly created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL NETWORKING REQUIREMENT:
# Create a Standard SKU Public IP address for the VM.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard"
  allocation_method   = "Static"
}

# Create a Network Interface for the Virtual Machine.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    private_ip_address_allocation = "Dynamic"
    # CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
    # Subnet ID must be from the dynamically created subnet.
    subnet_id                     = azurerm_subnet.this_subnet.id
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }

  # CRITICAL NIC/NSG ASSOCIATION RULE:
  # You are FORBIDDEN from adding a 'network_security_group_id' argument here.
  # NSG association is handled by 'azurerm_subnet_network_security_group_association'.
}

# Deploy the Virtual Machine
# CRITICAL INSTRUCTION: Name the primary compute resource "this_vm".
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser"
  # CRITICAL WINDOWS PASSWORD INSTRUCTIONS: Set the administrator password.
  admin_password      = random_password.admin_password.result
  network_interface_ids = [azurerm_network_interface.this_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128 # Default disk size for Windows OS
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Use the exact custom image name.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-19363652771"

  # CRITICAL AZURE VM ARGUMENT INSTRUCTION: 'azurerm_windows_virtual_machine' does not support a top-level 'enabled' argument.

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS: Enable serial console.
  boot_diagnostics {}

  # USER DATA/CUSTOM SCRIPT: Pass custom script via custom_data, base64 encoded.
  custom_data = base64encode(var.custom_script)
}

# Output block named "private_ip" that exposes the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output block named "instance_id" that exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine in Azure."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS: Output the generated admin password as sensitive.
output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}