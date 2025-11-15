# This Terraform HCL script deploys an Azure Windows Virtual Machine
# following strict guidelines for private cloud infrastructure as code.
# It includes robust networking, tenant isolation, and secure password management.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0" # Ensure compatibility with Azure provider features
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

# Configure the Microsoft Azure Provider.
# 'skip_provider_registration' is critical in environments where the service principal
# used by CI/CD lacks permissions to register resource providers.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# Declare Terraform variables for key configuration values.
# All variables include 'default' values directly from the provided JSON
# to ensure the script does not interactively prompt for input.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "67"
}

variable "region" {
  description = "The Azure region specified in the configuration. Note: The actual location for resources will be derived from the existing resource group."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size of the virtual machine (e.g., Standard_B1s)."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used in naming conventions for tenant-specific resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom PowerShell script to execute on the Windows VM after deployment."
  type        = string
  default     = "# Enter your post-deployment script here.\n# For Linux, it will be executed via bash.\n# For Windows, it will be executed via PowerShell.\n"
}

variable "resource_group_name" {
  description = "The name of the pre-existing Azure Resource Group where resources will be deployed."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# Data source to look up the existing Azure Resource Group.
# This ensures that no new resource group is created, preventing errors.
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# Data source to robustly check for the existence of the tenant-specific Virtual Network (VNet).
# This is part of the "get-or-create" pattern, returning an empty list if not found.
# CRITICAL ANTI-CYCLE: No local variables are referenced within this data block.
data "azurerm_resources" "existing_vnet" {
  type                = "Microsoft.Network/virtualNetworks"
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the Virtual Network for the tenant.
# It is only created if `data.azurerm_resources.existing_vnet` returns no existing resources.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # A /16 network to host multiple /24 subnets.

  tags = {
    tenant_id = var.tenant_id
  }
}

# Generate a random integer (2-254) to create a dynamic and non-overlapping subnet address.
# This helps prevent IP address conflicts for subsequent deployments within the same VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Locals block to dynamically select the VNet ID and name.
# It chooses between the existing VNet (if found) or the newly created one.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet.resources) > 0 ? data.azurerm_resources.existing_vnet.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet.resources) > 0 ? data.azurerm_resources.existing_vnet.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
}

# Create a dedicated subnet for this specific virtual machine deployment.
# The subnet name and address prefix are made unique using the instance name and a random octet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"] # Dynamic /24 subnet.
}

# Data source to check for the existence of the tenant-specific Network Security Group (NSG).
# Part of the "get-or-create" pattern for tenant isolation.
# CRITICAL ANTI-CYCLE: No local variables are referenced within this data block.
data "azurerm_resources" "existing_nsg" {
  type                = "Microsoft.Network/networkSecurityGroups"
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the Network Security Group for the tenant.
# It is only created if `data.azurerm_resources.existing_nsg` returns no existing resources.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH from Azure's infrastructure for management purposes.
  # This provides a baseline for management connectivity, further rules can be added.
  security_rule {
    name                         = "AllowSSH_from_AzureCloud"
    priority                     = 1001
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "22" # Commonly used for management access
    source_address_prefix        = "AzureCloud" # Tag for Azure's own internal services
    destination_address_prefix   = "*"
  }

  tags = {
    tenant_id = var.tenant_id
  }
}

# Locals block to dynamically select the NSG ID.
# It chooses between the existing NSG (if found) or the newly created one.
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg.resources) > 0 ? data.azurerm_resources.existing_nsg.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Associate the newly created subnet with the tenant's Network Security Group.
# CRITICAL: This association is done at the subnet level, ensuring all VMs in the subnet
# are protected by the same NSG rules. The network interface itself does not have an NSG ID.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Standard SKU Public IP address for the VM.
# A public IP is required for management agents (like SSM/Azure VM Agent extensions)
# to connect if the VM is in a subnet without NAT Gateway or other outbound connectivity solutions.
# Standard SKU ensures better availability and features compared to Basic.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: Standard SKU for robust deployments.

  tags = {
    tenant_id = var.tenant_id
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
    tenant_id = var.tenant_id
  }
}

# Generate a strong, random password for the Windows Administrator account.
# This ensures unique and secure credentials for each deployment.
resource "random_password" "admin_password" {
  length        = 16
  special       = true
  override_special = "_!@#&" # Defines the set of special characters to use.
}

# Deploy the Azure Windows Virtual Machine.
# This resource is named "this_vm" as required.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = "pmsadmin" # A default administrator username.
  admin_password      = random_password.admin_password.result # Use the generated random password.
  network_interface_ids = [azurerm_network_interface.this_nic.id]

  # CRITICAL: Use the exact custom image name provided in the instructions.
  # This image ID format points to a custom managed image in the specified resource group.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-azure-19379993972"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128 # Default OS disk size.
  }

  # CRITICAL: Enable boot diagnostics for accessing serial console logs.
  # This is invaluable for troubleshooting VM boot issues.
  boot_diagnostics {}

  # Custom data for post-deployment scripts.
  # For Azure Windows VMs, this is typically a PowerShell script and must be Base64 encoded.
  custom_data = base64encode(var.custom_script)

  # Assign tags for resource management, cost allocation, and identification.
  tags = {
    environment   = "private-cloud"
    tenant_id     = var.tenant_id
    instance_name = var.instance_name
  }
}

# Output the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the Azure Resource ID of the virtual machine.
output "instance_id" {
  description = "The Azure Resource ID of the virtual machine."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Output the randomly generated administrator password for the Windows VM.
# CRITICAL: This output is marked as sensitive to prevent its value from being
# displayed in plain text in Terraform CLI output or state files (if not configured).
output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}