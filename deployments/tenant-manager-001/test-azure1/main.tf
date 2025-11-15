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
# Disable automatic resource provider registration as the service principal may not have permissions.
provider "azurerm" {
  subscription_id        = var.subscription_id
  skip_provider_registration = true
  features {}
}

# Input variables for key configuration values from the JSON.
# Each variable includes a default value derived directly from the provided configuration.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azure1"
}

variable "region" {
  description = "The Azure region where the resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "The unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to be executed post-deployment."
  type        = string
  default     = "# Enter your post-deployment script here.\n# For Linux, it will be executed via bash.\n# For Windows, it will be executed via PowerShell.\n"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# Data source to look up the existing Azure Resource Group.
# The resource group is assumed to exist and is not created by this script.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Data source to look for an existing Virtual Network (VNet) for tenant isolation.
# This ensures a "get-or-create" pattern for the VNet.
# CRITICAL ANTI-CYCLE: No 'local' variables are referenced here.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Data source to look for an existing Network Security Group (NSG) for tenant isolation.
# This ensures a "get-or-create" pattern for the NSG.
# CRITICAL ANTI-CYCLE: No 'local' variables are referenced here.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Generate a random password for the Windows Administrator account.
# This ensures a strong, unique password for each deployment.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# Generate a random integer for the subnet octet to prevent address conflicts.
# This helps create a unique /24 subnet for each deployment within the tenant's VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Locals block to select the appropriate VNet and NSG IDs based on whether they were found or created.
locals {
  # Select the VNet ID: existing if found, otherwise from the newly created VNet.
  vnet_id = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  # Select the VNet Name: existing if found, otherwise from the newly created VNet.
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name

  # Select the NSG ID: existing if found, otherwise from the newly created NSG.
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# Conditionally create an Azure Virtual Network (VNet) for the tenant.
# It is created only if a VNet with the specified tenant name does not already exist.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    tenant = var.tenant_id
  }
}

# Create a unique subnet within the tenant's VNet for this specific deployment.
# The subnet name and address prefix use a random octet to prevent collisions.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Conditionally create an Azure Network Security Group (NSG) for the tenant.
# It is created only if an NSG with the specified tenant name does not already exist.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Rule to allow SSH access from Azure Cloud for management purposes.
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

  tags = {
    tenant = var.tenant_id
  }
}

# Associate the newly created subnet with the selected Network Security Group.
# This is the CRITICAL point for applying NSG rules to the subnet.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Standard SKU Public IP address for the VM.
# Standard SKU and Static allocation are required for robust deployments.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    environment = var.tenant_id
  }
}

# Create an Azure Network Interface for the virtual machine.
# It is associated with the dynamically created subnet and the public IP address.
# CRITICAL NIC/NSG ASSOCIATION RULE: 'network_security_group_id' is FORBIDDEN here.
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
    environment = var.tenant_id
  }
}

# Deploy the Azure Windows Virtual Machine.
# This resource uses the selected network interface, custom image, and generated password.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser"
  admin_password      = random_password.admin_password.result
  network_interface_ids = [azurerm_network_interface.this_nic.id]

  # CRITICAL AZURE VM ARGUMENT INSTRUCTION: The 'enabled' argument is FORBIDDEN here.

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # CRITICAL IMAGE NAME: Use the exact, provided custom image name.
  # The source_image_id is constructed to reference the custom image in the resource group.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-azure-19379993972"

  # Pass custom script data to the VM. For Azure, it's base64 encoded.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  tags = {
    environment = var.tenant_id
  }
}

# Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID of the created virtual machine.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Output the randomly generated administrator password.
# This output is marked as sensitive to prevent it from being displayed in plaintext in logs.
output "admin_password" {
  description = "The administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}