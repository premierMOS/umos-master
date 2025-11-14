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
# CRITICAL: Disabling provider registration as the service principal may not have permissions.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# Declare Terraform variables with default values from the JSON configuration
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-winj"
}

variable "region" {
  description = "The Azure region where the resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size/SKU of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "Optional custom script to run on VM startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "os_image_name" {
  description = "The exact name of the custom Windows OS image."
  type        = string
  default     = "windows-2019-19363652771"
}

# CRITICAL: Data source for the existing Azure Resource Group.
# The resource group is assumed to exist and will not be created by Terraform.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Generate a random password for the Windows Administrator account.
# CRITICAL: This password will be used for the VM.
resource "random_password" "admin_password" {
  length          = 16
  special         = true
  override_special = "_!@#&"
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Data source to check for an existing Virtual Network for the tenant.
# CRITICAL ANTI-CYCLE INSTRUCTION: No local variables referenced here.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  # This data source is intentionally configured to potentially fail if the VNet doesn't exist.
  # The 'count' meta-argument on the resource will handle conditional creation.
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Conditionally create the Virtual Network if it doesn't already exist.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    environment = "tenant-isolated"
    tenant_id   = var.tenant_id
  }
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Data source to check for an existing Network Security Group for the tenant.
# CRITICAL ANTI-CYCLE INSTRUCTION: No local variables referenced here.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
  # This data source is intentionally configured to potentially fail if the NSG doesn't exist.
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Conditionally create the Network Security Group if it doesn't already exist.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Rule to allow SSH from Azure infrastructure (for management/hybrid connectivity)
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
    environment = "tenant-isolated"
    tenant_id   = var.tenant_id
  }
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Local variables to select the correct VNet and NSG attributes (either existing or newly created).
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Generate a random octet for the subnet address to prevent collisions.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Create a new, non-overlapping subnet for this deployment within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # CRITICAL: Dynamic /24 subnet address using the random octet
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Associate the created subnet with the tenant's Network Security Group.
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
  sku                 = "Standard" # CRITICAL AZURE IP SKU: Must be Standard
  domain_name_label   = "${var.instance_name}-public" # Optional, but useful for DNS
  tags = {
    tenant_id = var.tenant_id
  }
}

# Create a Network Interface for the Virtual Machine
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id # CRITICAL: Subnet from newly created/selected subnet
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id # CRITICAL: Associate with public IP
  }

  tags = {
    tenant_id = var.tenant_id
  }
  # CRITICAL NIC/NSG ASSOCIATION RULE: network_security_group_id is FORBIDDEN here.
  # Association is done via azurerm_subnet_network_security_group_association.
}

# Create the Azure Windows Virtual Machine
# CRITICAL: Resource name must be "this_vm"
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser" # Standard admin username for Azure Windows VMs
  admin_password      = random_password.admin_password.result # CRITICAL: Use generated password

  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 127 # Default disk size for many images
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Use the exact specified image name.
  # Construct the source_image_id path using the custom image.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  # CRITICAL USER DATA/CUSTOM SCRIPT: Custom script for the VM.
  # For Azure Windows VMs, custom_data accepts base64 encoded scripts.
  custom_data = base64encode(var.custom_script)

  # CRITICAL: Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  tags = {
    environment = "production"
    purpose     = "webserver"
    tenant_id   = var.tenant_id
  }

  # CRITICAL AZURE VM ARGUMENT INSTRUCTION: The 'enabled' argument is FORBIDDEN for VM resources.
}

# Output the private IP address of the VM
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID
output "instance_id" {
  description = "The ID of the virtual machine instance."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS: Output the generated admin password as sensitive
output "admin_password" {
  description = "The administrator password for the Windows VM. This value is sensitive."
  value       = random_password.admin_password.result
  sensitive   = true
}