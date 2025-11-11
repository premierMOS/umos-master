# Terraform block to specify the required providers and their versions.
# This ensures that the correct provider plugins are downloaded and used.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Configure the AzureRM provider.
# CRITICAL: `features {}` and `skip_provider_registration = true` are required
# to prevent permissions errors in the CI/CD environment.
provider "azurerm" {
  subscription_id          = var.subscription_id
  features {}
  skip_provider_registration = true # Required for specific environment setup
}

# Declare Terraform variables for key configuration values,
# each with a default value extracted directly from the JSON configuration.
# This makes the script non-interactive and reusable.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azuree"
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
  description = "A unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to run on the VM during provisioning (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "resource_group_name" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

# Data source to retrieve an existing Azure Resource Group.
# CRITICAL: We are forbidden from creating a new resource group; we must reference an existing one.
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# --- Tenant Isolation: Virtual Network (VNet) Get-or-Create Pattern ---

# Data source to query for an existing Virtual Network based on tenant ID.
# CRITICAL: The 'name' argument MUST be set to "pmos-tenant-${var.tenant_id}-vnet".
# The 'filter' block is explicitly forbidden for this data source.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# Conditionally create a new Azure Virtual Network if one does not already exist for the tenant.
# The `count` meta-argument ensures creation only if `existing_vnet_query` finds no resources.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space
}

# --- Tenant Isolation: Network Security Group (NSG) Get-or-Create Pattern ---

# Data source to query for an existing Network Security Group based on tenant ID.
# CRITICAL: The 'name' argument MUST be set to "pmos-tenant-${var.tenant_id}-nsg".
# The 'filter' block is explicitly forbidden for this data source.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}

# Conditionally create a new Azure Network Security Group if one does not already exist for the tenant.
# The `count` meta-argument ensures creation only if `existing_nsg_query` finds no resources.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH access for Linux VMs (as per OS type in JSON)
  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # SSH port
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# Local variables to abstract the VNet and NSG IDs,
# conditionally selecting between existing resources or newly created ones.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? data.azurerm_resources.existing_nsg_query.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Create a dedicated subnet for this deployment within the selected VNet.
# Its name must be unique based on the instance name.
# CRITICAL: 'tags' argument is forbidden for azurerm_subnet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.1.0/24"] # Example subnet prefix
}

# Associate the newly created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL NETWORKING REQUIREMENT: Create an Azure Public IP address with Standard SKU.
# This ensures connectivity for management agents.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: MUST be Standard
}

# Create an Azure Network Interface for the virtual machine.
# It's associated with the new subnet and the public IP.
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

# Generate a new SSH key pair for administrative access to the Linux VM.
# CRITICAL: The 'comment' argument is FORBIDDEN in 'tls_private_key'.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Deploy an Azure Linux Virtual Machine.
# CRITICAL: The primary compute resource MUST be named "this_vm".
# CRITICAL: No top-level 'enabled' argument is allowed for azurerm_linux_virtual_machine.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  location                        = data.azurerm_resource_group.rg.location
  resource_group_name             = data.azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = "azureuser" # Standard admin user for Linux
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this_nic.id]

  # SSH public key for admin access, sourced from the generated TLS key.
  admin_ssh_key {
    username  = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Use the exact provided image name.
  # The source_image_id must be a fully qualified resource ID.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  # Pass custom script as user data, base64 encoded.
  # CRITICAL: Use 'custom_data' and 'base64encode()'.
  custom_data = base64encode(var.custom_script)

  # CRITICAL: Enable boot diagnostics for serial console access.
  boot_diagnostics {}
}

# Output the private IP address of the created virtual machine.
# CRITICAL: Output block MUST be named "private_ip".
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
# CRITICAL: Output block MUST be named "instance_id".
output "instance_id" {
  description = "The ID of the virtual machine instance."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key.
# CRITICAL: Output block MUST be named "private_ssh_key" and marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}