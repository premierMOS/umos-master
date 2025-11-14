# Configure the Terraform backend (e.g., Azure Storage Account, S3, etc.)
# for production use. For simplicity, this example uses local backend.
terraform {
  required_version = ">= 1.0"

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
# CRITICAL AZURE PROVIDER CONFIGURATION:
# The service principal used in the CI/CD environment does not have the necessary
# permissions to register providers. 'skip_provider_registration' is essential here.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# Declare Terraform variables for key configuration values from the JSON.
# Every variable declaration MUST include a 'default' value directly from the provided configuration.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-win"
}

variable "region" {
  description = "The Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "Base64 encoded custom data for the VM startup script."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group_name" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS:
# Generate a secure random password for the administrator account.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# CRITICAL AZURE RESOURCE GROUP INSTRUCTION:
# The Azure Resource Group specified in the configuration ALREADY EXISTS.
# Use a 'data "azurerm_resource_group"' block to look up the existing one.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Data source to check for an existing Virtual Network (VNet) for the tenant.
# CRITICAL ANTI-CYCLE INSTRUCTION: Do not reference local variables within data blocks.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the Virtual Network if the lookup fails.
# Uses 'count' meta-argument based on the data source lookup.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    Environment = "PrivateCloud"
    Tenant      = var.tenant_id
  }
}

# Local variables to abstract the VNet ID and name, whether it was existing or newly created.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Generate a random integer for a unique subnet octet to prevent address conflicts.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a new, non-overlapping subnet for this deployment within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # CRITICAL: Use the random number to create a unique /24 subnet.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Data source to check for an existing Network Security Group (NSG) for the tenant.
# CRITICAL ANTI-CYCLE INSTRUCTION: Do not reference local variables within data blocks.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the Network Security Group if the lookup fails.
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
  # Security rule to allow SSH from Azure's infrastructure.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # As per instruction for SSH
    source_address_prefix      = "AzureCloud"
    destination_address_prefix = "*"
  }

  tags = {
    Environment = "PrivateCloud"
    Tenant      = var.tenant_id
  }
}

# Local variable to abstract the NSG ID, whether it was existing or newly created.
locals {
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Associate the newly created subnet with the tenant's NSG.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL NETWORKING REQUIREMENT:
# Create a Public IP address for the VM to ensure connectivity for management agents.
# CRITICAL AZURE IP SKU: The 'azurerm_public_ip' resource MUST use sku = "Standard" and allocation_method = "Static".
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1"] # For Standard SKU, zones are required in some regions (e.g., East US).
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

  # CRITICAL NIC/NSG ASSOCIATION RULE:
  # The NSG association MUST be done via the azurerm_subnet_network_security_group_association resource.
  # DO NOT add 'network_security_group_id' here.
}

# Deploy the Azure Windows Virtual Machine.
# CRITICAL VM ARGUMENT INSTRUCTION: The 'azurerm_windows_virtual_machine' resource
# DOES NOT support a top-level 'enabled' argument.
resource "azurerm_windows_virtual_machine" "this_vm" {
  # Name the primary compute resource "this_vm" as per instructions.
  name                = var.instance_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = "azureadmin"
  # CRITICAL WINDOWS PASSWORD INSTRUCTIONS: Set the administrator password from the generated random password.
  admin_password      = random_password.admin_password.result
  network_interface_ids = [azurerm_network_interface.this_nic.id]

  # CRITICAL IMAGE NAME INSTRUCTION: Using the exact cloud image name provided for Azure.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-19363652771"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128
  }

  # USER DATA/CUSTOM SCRIPT: Pass custom_script to custom_data, base64 encoded.
  custom_data = base64encode(var.custom_script)

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
  # Enable Boot Diagnostics for serial console access.
  boot_diagnostics {}

  tags = {
    Environment = "PrivateCloud"
    Tenant      = var.tenant_id
  }
}

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

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS:
# Output the generated administrator password, marked as sensitive.
output "admin_password" {
  description = "The generated administrator password for the VM."
  value       = random_password.admin_password.result
  sensitive   = true
}