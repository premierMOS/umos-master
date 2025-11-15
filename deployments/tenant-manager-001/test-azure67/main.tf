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

# Configure the Azure provider
# Critical: skip_provider_registration is used to prevent permissions errors
# in environments where the service principal lacks registration permissions.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# Declare variables with default values pulled directly from the JSON configuration.
# This ensures the script can run without interactive prompts.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azure67"
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
  description = "A unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to execute on the VM after deployment."
  type        = string
  default     = "# Enter your post-deployment script here.\n# For Linux, it will be executed via bash.\n# For Windows, it will be executed via PowerShell.\n"
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

variable "source_image_id" {
  description = "The specific ID of the custom Windows image to use."
  type        = string
  default     = "windows-2019-azure-19379993972"
}

# Look up the existing Azure Resource Group.
# Critical: This data source is used because the RG is assumed to pre-exist.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Generate a random password for the Windows administrator account.
# Critical: This ensures a strong, unique password for each deployment.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# --- Azure Networking - Tenant Isolation (Get-or-Create VNet & NSG, Dynamic Subnet) ---

# Data source to check if the tenant's Virtual Network already exists.
# Critical: This is part of the "get-or-create" pattern. Returns empty list if not found.
# Critical: NO local variables are referenced within this data block.
data "azurerm_resources" "existing_vnet" {
  type                = "Microsoft.Network/virtualNetworks"
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the tenant's Virtual Network if it doesn't already exist.
# Critical: count meta-argument ensures creation only if lookup fails.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    tenant_id = var.tenant_id
  }
}

# Local variables to dynamically select the VNet ID and Name based on whether it was found or created.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet.resources) > 0 ? data.azurerm_resources.existing_vnet.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet.resources) > 0 ? data.azurerm_resources.existing_vnet.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
}

# Generate a random octet for the subnet address to prevent conflicts.
# Critical: Ensures dynamic, non-overlapping subnet creation for each deployment.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a new subnet for this VM within the tenant's VNet.
# Critical: Subnet address is dynamically generated to ensure uniqueness.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Data source to check if the tenant's Network Security Group already exists.
# Critical: Part of the "get-or-create" pattern. Returns empty list if not found.
# Critical: NO local variables are referenced within this data block.
data "azurerm_resources" "existing_nsg" {
  type                = "Microsoft.Network/networkSecurityGroups"
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the tenant's Network Security Group if it doesn't already exist.
# Critical: count meta-argument ensures creation only if lookup fails.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Critical: Rule to allow SSH from Azure infrastructure, often for management agents.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # As specified in instructions
    source_address_prefix      = "AzureCloud"
    destination_address_prefix = "*"
  }

  tags = {
    tenant_id = var.tenant_id
  }
}

# Local variable to dynamically select the NSG ID based on whether it was found or created.
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg.resources) > 0 ? data.azurerm_resources.existing_nsg.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Associate the newly created subnet with the tenant's Network Security Group.
# Critical: This is the ONLY method permitted for NSG association to the subnet.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create an Azure Public IP address.
# Critical: Standard SKU and Static allocation are mandatory.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags = {
    instance_name = var.instance_name
  }
}

# Create a Network Interface for the Virtual Machine.
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
    instance_name = var.instance_name
  }
}

# Deploy the Azure Windows Virtual Machine.
# Critical: Resource name MUST be 'this_vm'.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = "azureuser"
  admin_password      = random_password.admin_password.result # Critical: Use the generated random password.

  # Critical: Associate the VM with the Network Interface.
  network_interface_ids = [azurerm_network_interface.this_nic.id]

  # Operating System Disk Configuration
  os_disk {
    name                 = "${var.instance_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Critical: Use the specific custom image ID provided.
  # The full path is constructed using subscription ID and resource group.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.source_image_id}"

  # Critical: Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # Custom Data (User Data) for Azure VMs.
  # Critical: For Azure, use custom_data with base64 encoding.
  custom_data = base64encode(var.custom_script)

  tags = {
    instance_name = var.instance_name
    tenant_id     = var.tenant_id
  }
}

# Output the private IP address of the deployed VM.
# Critical: Exposes the internal IP for connectivity within the network.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
# Critical: Useful for referencing the VM directly in the Azure portal or CLI.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Output the generated administrator password.
# Critical: Marked as sensitive to prevent it from being displayed in plaintext in logs.
output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}