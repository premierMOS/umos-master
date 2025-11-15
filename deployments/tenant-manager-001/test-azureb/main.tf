terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0" # Ensure compatibility with Azure APIs
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

# Declare Terraform variables for key configuration values from the JSON.
# Each variable includes a 'default' value set directly from the provided configuration,
# preventing interactive prompts.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azureb"
}

variable "region" {
  description = "The Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size of the virtual machine (e.g., Standard_B1s, Standard_D2s_v3)."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming to ensure isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "User-provided post-deployment script to be executed on the VM."
  type        = string
  default     = "# Enter your post-deployment script here.\n# For Linux, it will be executed via bash.\n# For Windows, it will be executed via PowerShell.\n"
}

variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "admin_username" {
  description = "The administrator username for the Windows virtual machine."
  type        = string
  default     = "azureuser" # A common default for Azure Windows VMs
}

# CRITICAL IMAGE NAME INSTRUCTION:
# The specific cloud image name for this deployment.
variable "source_image_name" {
  description = "The exact name of the custom Windows image in Azure Compute Gallery or as a managed image."
  type        = string
  default     = "windows-2019-azure-19379993972"
}

# CRITICAL AZURE PROVIDER CONFIGURATION:
# Configure the Azure provider.
# 'skip_provider_registration = true' is essential for CI/CD environments to avoid permissions errors.
provider "azurerm" {
  features {} # Required to enable new Azure Provider features
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS:
# Generate a strong, random password for the administrator of the Windows VM.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&" # Characters to use for special characters
}

# CRITICAL AZURE RESOURCE GROUP INSTRUCTION:
# Look up the existing Azure Resource Group. This script is FORBIDDEN from creating a new one.
data "azurerm_resource_group" "rg" {
  name = "umos"
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Data source to check if a Virtual Network for this tenant already exists.
# CRITICAL ANTI-CYCLE INSTRUCTION: Arguments here must be from variables or other data sources directly.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the Virtual Network if the lookup above failed (i.e., it doesn't exist).
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space for the VNet

  tags = {
    Environment = "Production"
    Tenant      = var.tenant_id
  }
}

# Local variables to abstract the VNet ID and name, whether it was existing or newly created.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Generate a random integer for a unique subnet octet to prevent address space collisions.
resource "random_integer" "subnet_octet" {
  min = 2   # Avoid 0 (network address) and 1 (usually gateway/reserved)
  max = 254 # Maximum valid octet for a /24 subnet in the 10.0.x.0/24 range
}

# Create a new, unique subnet for THIS deployment within the tenant's Virtual Network.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # CRITICAL: Use the random octet to create a unique /24 subnet address.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Data source to check if a Network Security Group for this tenant already exists.
# CRITICAL ANTI-CYCLE INSTRUCTION: Arguments here must be from variables or other data sources directly.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the Network Security Group if the lookup above failed.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
  # Security rule to allow SSH from Azure's infrastructure.
  # Instruction specified destination port 22 even for Windows, for management.
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

  tags = {
    Environment = "Production"
    Tenant      = var.tenant_id
  }
}

# Local variable to abstract the NSG ID, whether it was existing or newly created.
locals {
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# Associate the created subnet with the tenant's Network Security Group.
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
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL AZURE IP SKU: Standard SKU is required.

  tags = {
    Environment = "Production"
    Tenant      = var.tenant_id
  }
}

# Create the Network Interface (NIC) for the virtual machine.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id # Associate the public IP
  }

  tags = {
    Environment = "Production"
    Tenant      = var.tenant_id
  }
  # CRITICAL NIC/NSG ASSOCIATION RULE:
  # The NSG is associated with the subnet, not directly with the NIC.
  # Do NOT add 'network_security_group_id' here.
}

# Deploy the Azure Windows Virtual Machine.
# CRITICAL: The primary compute resource is named "this_vm".
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username
  # CRITICAL WINDOWS PASSWORD INSTRUCTIONS: Set the admin password from the generated random password.
  admin_password      = random_password.admin_password.result
  network_interface_ids = [azurerm_network_interface.this_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128 # Default OS disk size, can be made configurable
  }

  # CRITICAL IMAGE NAME INSTRUCTION:
  # Use the exact, full resource ID for the custom Windows image.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.source_image_name}"

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
  # Enable Boot Diagnostics to access serial console output for troubleshooting.
  boot_diagnostics {}

  # CRITICAL USER DATA & SSM AGENT INSTRUCTIONS:
  # For Azure, custom_data is used for startup scripts and must be base64 encoded.
  custom_data = base64encode(var.custom_script)

  tags = {
    Environment = "Production"
    Tenant      = var.tenant_id
  }

  # CRITICAL AZURE VM ARGUMENT INSTRUCTION:
  # 'azurerm_windows_virtual_machine' does not support a top-level 'enabled' argument.
  # Do NOT add 'enabled = false' or similar here.
}

# CRITICAL INSTRUCTION: Output block named "private_ip".
output "private_ip" {
  description = "The private IP address of the created virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# CRITICAL INSTRUCTION: Output block named "instance_id".
output "instance_id" {
  description = "The Azure ID of the created virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS: Output the generated administrator password.
output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true # Mark as sensitive to prevent plain-text display in logs/state
}