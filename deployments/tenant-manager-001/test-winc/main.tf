# Configure the AzureRM Provider
# The 'skip_provider_registration' is required for environments where the service principal lacks permissions
# to register resource providers.
# The 'subscription_id' is explicitly set to ensure operations occur within the intended subscription.
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
  subscription_id        = var.subscription_id
  skip_provider_registration = true # Required for specific CI/CD environments
}

# Declare Terraform variables with default values from the JSON configuration.
# This ensures the script can be run without interactive prompts.

variable "platform_name" {
  description = "The name of the cloud platform."
  type        = string
  default     = "Microsoft Azure"
}

variable "os_image_id" {
  description = "The OS image ID (friendly name) from the configuration."
  type        = string
  default     = "windows-2019-azure-1763120915349"
}

variable "platform" {
  description = "The specific platform identifier."
  type        = string
  default     = "Azure"
}

variable "instance_name" {
  description = "The desired name for the virtual machine instance."
  type        = string
  default     = "test-winc"
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

variable "custom_script" {
  description = "A custom script to be executed on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "os_name" {
  description = "The actual cloud image name used for lookup."
  type        = string
  default     = "windows-2019-azure-19363652771" # CRITICAL: This is the actual image name for lookup
}

variable "os_version" {
  description = "The version of the operating system."
  type        = string
  default     = "Custom Build"
}

variable "os_type" {
  description = "The type of operating system (e.g., Windows, Linux)."
  type        = string
  default     = "Windows"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for resource naming and isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "azure_resource_group_name" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# --- Data Sources for Existing Resources ---

# Look up the existing Azure Resource Group where resources will be deployed.
# This avoids attempting to create a resource group that already exists.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# Attempt to look up an existing Virtual Network dedicated to the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Attempt to look up an existing Network Security Group dedicated to the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# --- Random Resources for Dynamic Configuration ---

# Generate a random password for the Windows administrator account.
# This ensures strong, unique passwords for each deployment.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# Generate a random integer for creating a unique subnet address space.
# This prevents IP address conflicts when creating multiple subnets within the same VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# --- Conditional Resource Creation (Get-or-Create Pattern) ---

# Create a Virtual Network for the tenant if one does not already exist.
# The 'count' meta-argument implements the "get-or-create" logic.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # A common address space for tenant VNets
}

# Create a Network Security Group for the tenant if one does not already exist.
# This NSG will be associated with the subnet to control inbound/outbound traffic.
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH from Azure Cloud for management agents.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # SSH port
    source_address_prefix      = "AzureCloud" # Microsoft Azure's public IP space
    destination_address_prefix = "*"
  }
}

# --- Local Variables for Dynamic Selection ---

# Use local variables to conditionally select the VNet ID based on whether an existing
# VNet was found or a new one was created.
locals {
  vnet_id = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# --- Networking Resources ---

# Create a new, unique subnet within the selected VNet.
# The random octet ensures non-overlapping subnet address spaces for new deployments.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"] # Dynamic /24 subnet
}

# Associate the created subnet with the tenant's Network Security Group.
# This applies the security rules to all resources within this subnet.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Standard SKU Public IP address for the VM.
# Standard SKUs offer better features and are required for certain Azure services.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Create a Network Interface for the VM.
# This interface connects the VM to the subnet and associates the public IP.
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
  # CRITICAL: NSG association is handled by azurerm_subnet_network_security_group_association,
  # not directly on the NIC to prevent conflicts and ensure tenant-wide policy.
}

# --- Virtual Machine Resource ---

# Deploy the Azure Windows Virtual Machine.
# Named "this_vm" as per instructions.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser" # Standard admin username
  admin_password      = random_password.admin_password.result
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # Standard storage for OS disk
  }

  # CRITICAL: Use the exact custom image name provided.
  # The source_image_id must be a full resource ID.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_name}"

  # Pass custom data (user data) to the VM, base64 encoded.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # CRITICAL: The 'enabled' argument is not supported for azurerm_windows_virtual_machine.
}

# --- Outputs ---

# Output the private IP address of the virtual machine's primary network interface.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the Azure resource ID of the virtual machine.
output "instance_id" {
  description = "The Azure ID of the deployed virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Output the generated administrator password.
# This output is marked as sensitive to prevent it from being displayed in plaintext
# in Terraform logs or state file outputs.
output "admin_password" {
  description = "The generated administrator password for the VM."
  value       = random_password.admin_password.result
  sensitive   = true
}