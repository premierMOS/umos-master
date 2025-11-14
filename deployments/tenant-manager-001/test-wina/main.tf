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

provider "azurerm" {
  features {}
  # The subscription_id is retrieved from the variable
  subscription_id = var.subscription_id
  # Disables automatic resource provider registration, which is required when the service principal lacks permissions.
  skip_provider_registration = true
}

# Terraform variables for key configuration values, with default values directly from the JSON.
variable "instance_name" {
  type        = string
  description = "Name of the virtual machine instance."
  default     = "test-wina"
}

variable "region" {
  type        = string
  description = "Azure region where resources will be deployed."
  default     = "East US"
}

variable "vm_size" {
  type        = string
  description = "Size of the virtual machine."
  default     = "Standard_B1s"
}

variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant, used for resource naming and isolation."
  default     = "tenant-manager-001"
}

variable "custom_script" {
  type        = string
  description = "Custom script to be executed on the VM during provisioning via custom data."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  type        = string
  description = "Name of the existing Azure Resource Group where resources will be deployed."
  default     = "umos"
}

variable "subscription_id" {
  type        = string
  description = "The Azure Subscription ID."
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# Data source to retrieve details of the existing Azure Resource Group.
# This avoids creating a new resource group and leverages an already provisioned one.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Data source to check for an existing Virtual Network (VNet) for the tenant.
# This prevents circular dependencies by directly referencing variables and other data sources.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Data source to check for an existing Network Security Group (NSG) for the tenant.
# This prevents circular dependencies by directly referencing variables and other data sources.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Generate a random password for the Windows VM administrator.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# Generate a random integer for the subnet octet to ensure unique, non-overlapping subnets.
resource "random_integer" "subnet_octet" {
  min = 2  # Start from 2 to avoid common network/broadcast addresses in smaller ranges
  max = 254
}

# Locals block to conditionally select the VNet ID and name based on whether it was found or created.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# Conditionally create an Azure Virtual Network (VNet) for tenant isolation.
# The 'count' meta-argument ensures creation only if no existing VNet is found by the data source.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  address_space       = ["10.0.0.0/16"] # Example address space for the tenant VNet
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create an Azure Network Security Group (NSG) for tenant isolation.
# The 'count' meta-argument ensures creation only if no existing NSG is found by the data source.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH (port 22) from Azure's infrastructure for management purposes.
  # Note: For Windows VMs, RDP (3389) is typically used. This rule follows the exact instruction for SSH.
  security_rule {
    name                         = "AllowSSH_from_AzureCloud"
    priority                     = 1001
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "22"
    source_address_prefix        = "AzureCloud"
    destination_address_prefix   = "*"
  }
}

# Create a unique subnet for this VM deployment within the tenant's VNet.
# The subnet's name and address prefix incorporate a random octet to prevent collisions.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"] # Dynamic /24 subnet
}

# Associate the newly created subnet with the tenant's Network Security Group.
# This ensures all traffic to/from the subnet is filtered by the NSG rules.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Standard SKU Public IP address for the VM.
# This ensures connectivity and is required for management agents like Azure Arc/SSM.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Create an Azure Network Interface for the virtual machine.
# It connects to the dynamically created subnet and is assigned the public IP address.
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

# Deploy the Azure Windows Virtual Machine.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser" # Standard administrator username for Azure Windows VMs
  admin_password      = random_password.admin_password.result
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # Configuration for the OS disk.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Specifies the custom Windows image to be used for deployment.
  # The image ID is constructed using the subscription ID, resource group name, and the exact image name.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-19363652771"

  # Enables boot diagnostics for accessing serial console output.
  boot_diagnostics {}

  # Passes custom data (e.g., a startup script) to the VM.
  custom_data = base64encode(var.custom_script)
}

# Output the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the Azure-native instance ID of the virtual machine.
output "instance_id" {
  description = "The unique ID of the virtual machine in Azure."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Output the randomly generated administrator password for the VM.
# Marked as sensitive to prevent it from being displayed in plaintext in Terraform outputs.
output "admin_password" {
  description = "The randomly generated administrator password for the VM."
  value       = random_password.admin_password.result
  sensitive   = true
}