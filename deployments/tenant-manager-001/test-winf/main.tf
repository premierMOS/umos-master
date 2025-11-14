# Terraform block to specify required providers and their versions.
# The 'azurerm' provider is for interacting with Azure resources.
# The 'random' provider is used for generating unique values, such as passwords and subnet octets.
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

# Azure Provider Configuration.
# 'subscription_id' is set from a variable to ensure it's configurable.
# 'skip_provider_registration' is set to true as per critical instructions for CI/CD environments.
provider "azurerm" {
  features {} # Required for the AzureRM provider to function correctly.
  subscription_id        = var.subscription_id
  skip_provider_registration = true # CRITICAL: Required to prevent permissions errors in specific CI/CD environments.
}

# --- Input Variables ---
# CRITICAL VARIABLE INSTRUCTION: All key configuration values from the JSON are declared as variables
# with their default values set directly from the provided configuration. This prevents interactive prompts.

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-winf" # Value from JSON: platform.instanceName
}

variable "region" {
  description = "Azure region where resources will be deployed."
  type        = string
  default     = "East US" # Value from JSON: platform.region
}

variable "vm_size" {
  description = "Size of the virtual machine (e.g., Standard_B1s)."
  type        = string
  default     = "Standard_B1s" # Value from JSON: platform.vmSize
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming to ensure isolation."
  type        = string
  default     = "tenant-manager-001" # Value from JSON: tenantId
}

variable "custom_script" {
  description = "Custom script to run on the VM during provisioning (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n" # Value from JSON: platform.customScript
}

variable "azure_resource_group_name" {
  description = "Name of the existing Azure Resource Group where resources will be deployed."
  type        = string
  default     = "umos" # Value from JSON: azure_resource_group
}

variable "subscription_id" {
  description = "Azure subscription ID to deploy resources into."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33" # Value from JSON: azure_subscription_id
}

# --- Data Sources ---

# CRITICAL AZURE RESOURCE GROUP INSTRUCTION:
# Data source to reference the existing Azure Resource Group.
# This avoids attempting to create a resource group that already exists, preventing errors.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Data source to look for an existing Virtual Network (VNet) for the specific tenant.
# CRITICAL ANTI-CYCLE INSTRUCTION: References 'var.tenant_id' and 'data.azurerm_resource_group.rg.name' directly
# to avoid circular dependencies with 'locals' blocks.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Data source to look for an existing Network Security Group (NSG) for the specific tenant.
# CRITICAL ANTI-CYCLE INSTRUCTION: References 'var.tenant_id' and 'data.azurerm_resource_group.rg.name' directly
# to avoid circular dependencies with 'locals' blocks.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# --- Locals Block for Conditional Resource Selection ---
# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# This block dynamically determines whether to use the ID/name of an existing VNet/NSG
# or the ID/name of a newly created VNet/NSG based on the lookup results.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}


# --- Resources ---

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS:
# Creates a random, strong password for the Windows administrator account.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&" # Specific special characters as per instruction.
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Conditionally creates a Virtual Network if the 'existing_vnet' data source lookup fails.
# This ensures a dedicated VNet per tenant, creating it only if it doesn't already exist.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space for the VNet.

  tags = {
    tenant = var.tenant_id
  }
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Generates a random integer to create a unique subnet address prefix.
# This prevents address space collisions for new subnets within the tenant VNet.
resource "random_integer" "subnet_octet" {
  min = 2  # Starting from 2 to leave 0 and 1 for gateway/future use if needed.
  max = 254 # Max value for a /24 subnet's third octet.
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Creates a NEW, non-overlapping subnet for THIS deployment within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name # Uses the VNet name from the 'locals' block (existing or new).
  # CRITICAL: Dynamically generates a /24 subnet address prefix using the random octet.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Conditionally creates a Network Security Group (NSG) if the 'existing_nsg' data source lookup fails.
# This ensures a dedicated NSG per tenant, creating it only if it doesn't already exist.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION:
  # Security rule to allow inbound SSH (port 22) traffic from Azure's infrastructure.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # SSH standard port
    source_address_prefix      = "AzureCloud" # Specific tag for Azure's public IP space.
    destination_address_prefix = "*"
  }

  tags = {
    tenant = var.tenant_id
  }
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION:
# Associates the dynamically created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id # Uses the NSG ID from the 'locals' block (existing or new).
}

# CRITICAL NETWORKING REQUIREMENT:
# Creates a Public IP address for the VM.
# CRITICAL AZURE IP SKU: The SKU MUST be "Standard" and allocation method "Static" as required.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL AZURE IP SKU: Standard SKU is mandatory.

  tags = {
    instance_name = var.instance_name
  }
}

# Network Interface for the Virtual Machine.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    # CRITICAL AZURE NETWORKING & TENANT ISOLATION:
    # Subnet ID must reference the dynamically created 'this_subnet'.
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id # Associates the public IP.
  }

  tags = {
    instance_name = var.instance_name
  }
  # CRITICAL NIC/NSG ASSOCIATION RULE:
  # The 'network_security_group_id' argument is FORBIDDEN here.
  # NSG association is handled by 'azurerm_subnet_network_security_group_association'.
}

# Primary Compute Resource: Azure Windows Virtual Machine.
# CRITICAL VM NAME: The resource is named "this_vm" as required.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = "azureuser" # Standard administrator username for Windows.

  # CRITICAL WINDOWS PASSWORD INSTRUCTIONS:
  # Sets the administrator password using the generated random password.
  admin_password      = random_password.admin_password.result

  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # CRITICAL IMAGE NAME INSTRUCTION:
  # Uses the exact custom image ID for the boot disk, formatted as per Azure's requirements.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-19363652771"

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION:
  # Enables boot diagnostics, which includes serial console access for troubleshooting.
  boot_diagnostics {}

  # USER DATA/CUSTOM SCRIPT:
  # For Azure Windows VMs, custom data is passed via 'custom_data' and must be base64 encoded.
  custom_data = base64encode(var.custom_script)

  tags = {
    instance_name = var.instance_name
    tenant        = var.tenant_id
  }
  # CRITICAL AZURE VM ARGUMENT INSTRUCTION:
  # The 'azurerm_windows_virtual_machine' resource does NOT support a top-level 'enabled' argument.
}


# --- Outputs ---

# CRITICAL INSTRUCTION:
# Output block named "private_ip" exposing the private IP address of the created VM.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# CRITICAL INSTRUCTION:
# Output block named "instance_id" exposing the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine within Azure."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# CRITICAL WINDOWS PASSWORD INSTRUCTIONS:
# Output block named "admin_password" exposing the generated administrator password.
# This output is marked as sensitive to prevent it from being displayed in plaintext in logs.
output "admin_password" {
  description = "The automatically generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}