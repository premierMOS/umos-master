# Terraform block specifies the required providers and their versions.
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

# Configure the AzureRM Provider.
# The 'skip_provider_registration' argument is set to true to prevent
# automatic resource provider registration, as the service principal
# may not have the necessary permissions in this environment.
provider "azurerm" {
  features {}
  subscription_id            = var.subscription_id
  skip_provider_registration = true
}

# Declare Terraform variables for key configuration values.
# Each variable includes a 'default' value directly from the provided JSON,
# preventing interactive prompts during script execution.

variable "instance_name" {
  description = "The name for the virtual machine instance."
  type        = string
  default     = "test-win"
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

variable "custom_script" {
  description = "A custom script to be executed on the VM upon startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "subscription_id" {
  description = "The Azure subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "azure_resource_group_name" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "image_name" {
  description = "The exact name of the custom Windows image to use."
  type        = string
  default     = "windows-2019-19363652771" # Critical: Use the specified exact image name
}

# --- Data Sources ---

# Data source to look up the existing Azure Resource Group.
# This avoids creating a new resource group and leverages an existing one.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# Data source to check for an existing Virtual Network (VNet) for the tenant.
# This implements a "get-or-create" pattern for tenant isolation.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Data source to check for an existing Network Security Group (NSG) for the tenant.
# This also implements a "get-or-create" pattern for tenant isolation.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# --- Random Resources ---

# Generates a random password for the Windows administrator account.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# Generates a random integer for dynamic subnet address allocation.
# This helps prevent subnet address conflicts on subsequent deployments.
resource "random_integer" "subnet_octet" {
  min = 2  # Start from 2 to avoid common gateway IPs (0 and 1)
  max = 254
}

# --- Locals Block for Conditional Resource Selection ---

# This block dynamically selects the VNet and NSG based on whether
# an existing resource was found or a new one was created.
locals {
  vnet_id = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# --- Networking Resources ---

# Conditionally creates a new Virtual Network (VNet) for the tenant
# if an existing one was not found.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space
}

# Creates a new subnet for the virtual machine within the tenant's VNet.
# The subnet's address prefix is dynamically generated using a random octet
# to prevent collisions.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Conditionally creates a new Network Security Group (NSG) for the tenant
# if an existing one was not found.
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH from Azure's infrastructure.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # Default SSH port
    source_address_prefix      = "AzureCloud" # Specific tag for Azure public IP space
    destination_address_prefix = "*"
  }
}

# Associates the newly created subnet with the tenant's NSG.
# This is the mandated method for NSG association, not directly on the NIC.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Creates a Standard SKU Public IP address for the VM.
# This ensures connectivity and is required for management agents in public subnets.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # Critical: Standard SKU required
}

# Creates a Network Interface (NIC) for the virtual machine.
# It is configured with a private IP from the subnet and associated with the public IP.
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
}

# --- Virtual Machine Resource ---

# Deploys the Windows virtual machine.
# Named "this_vm" as per instructions.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "pmoadmin" # Default Windows admin username
  admin_password      = random_password.admin_password.result # Critical: Use generated password
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # Critical: Custom image ID using the specified exact image name and subscription ID
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.image_name}"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Critical: Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # Critical: Pass custom script as base64 encoded custom_data.
  custom_data = base64encode(var.custom_script)
}

# --- Outputs ---

# Exposes the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Exposes the generated administrator password for the Windows VM.
# This output is marked as sensitive to prevent it from being displayed
# in plain text in logs or console output.
output "admin_password" {
  description = "The randomly generated administrator password for the VM."
  value       = random_password.admin_password.result
  sensitive   = true
}