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
# Disables automatic resource provider registration to avoid permission errors
# in CI/CD environments where the service principal lacks registration permissions.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true # Required for specific environment constraints
}

# --- Variables Block ---

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-wini"
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
  description = "Unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "Custom script to run on VM startup (base64 encoded for Azure)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  description = "Name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "os_image_name" {
  description = "The name of the custom OS image to use."
  type        = string
  default     = "windows-2019-19363652771" # CRITICAL: This exact value is required as per instructions
}

# --- Random Resources ---

# Generates a random password for the Windows Administrator account.
# This ensures a strong, unique password for each deployment.
resource "random_password" "admin_password" {
  length          = 16
  special         = true
  override_special = "_!@#&"
}

# Generates a random integer for the subnet octet to prevent address space collisions.
# Ensures a unique /24 subnet for each new VM deployment within the VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# --- Data Sources ---

# Looks up the existing Azure Resource Group.
# This resource group is assumed to exist and is not created by this script.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Attempts to find an existing Virtual Network (VNet) for the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
# CRITICAL: No local variables are referenced within this data block to prevent circular dependencies.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Attempts to find an existing Network Security Group (NSG) for the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
# CRITICAL: No local variables are referenced within this data block to prevent circular dependencies.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# --- Local Values ---

# Determines which VNet (existing or newly created) to use.
locals {
  vnet_id = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# --- Networking Resources (Get-or-Create Pattern) ---

# Conditionally creates a Virtual Network (VNet) for the tenant.
# This VNet is created only if an existing one is not found via the data source.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    Environment = "PrivateCloud"
    Tenant      = var.tenant_id
  }
}

# Conditionally creates a Network Security Group (NSG) for the tenant.
# This NSG is created only if an existing one is not found via the data source.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # Standard SSH port
    source_address_prefix      = "AzureCloud" # Allows SSH from Azure's management infrastructure
    destination_address_prefix = "*"
  }

  tags = {
    Environment = "PrivateCloud"
    Tenant      = var.tenant_id
  }
}

# Creates a unique subnet for this VM within the tenant's VNet.
# The address prefix uses a random octet to avoid collisions on subsequent deployments.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Associates the newly created subnet with the tenant's Network Security Group.
# This ensures that traffic to the subnet is governed by the tenant's NSG rules.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Creates a Standard SKU Public IP address for the VM.
# Required for outbound connectivity from instances in default public subnets for management agents.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: Standard SKU is required as per instructions

  tags = {
    Environment = "PrivateCloud"
    Tenant      = var.tenant_id
  }
}

# Creates a Network Interface Card (NIC) for the VM.
# The NIC is configured with a private IP from the subnet and associated with the public IP.
# CRITICAL: Do NOT add network_security_group_id here; association is via azurerm_subnet_network_security_group_association.
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

  tags = {
    Environment = "PrivateCloud"
    Tenant      = var.tenant_id
  }
}

# --- Virtual Machine Resource ---

# Deploys the Windows Virtual Machine.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureadmin"
  admin_password      = random_password.admin_password.result # Sets password from random_password resource

  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # CRITICAL: Custom image ID using the exact name specified in instructions
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  os_disk {
    name                 = "${var.instance_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128 # Default disk size
  }

  # Enables Boot Diagnostics for serial console access.
  boot_diagnostics {}

  # Passes custom script as user data (base64 encoded).
  custom_data = base64encode(var.custom_script)

  tags = {
    Environment = "PrivateCloud"
    Tenant      = var.tenant_id
  }
}

# --- Outputs Block ---

# Exposes the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.ip_configuration[0].private_ip_address
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The Azure ID of the deployed virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Exposes the randomly generated administrator password.
# This output is marked as sensitive to prevent it from being displayed in plaintext in logs.
output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}