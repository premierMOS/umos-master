# Required providers block
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Azure Provider Configuration
provider "azurerm" {
  features {}                        # CRITICAL: Disable automatic resource provider registration
  skip_provider_registration = true  # CRITICAL: Required for this environment
  subscription_id            = var.subscription_id
}

# ---------------------------------------------------------------------------------------------------------------------
# Terraform Variables - CRITICAL: All variables include default values from the JSON configuration.
# ---------------------------------------------------------------------------------------------------------------------

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-azureh-1"
}

variable "region" {
  description = "Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "Size of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "custom_script" {
  description = "Custom script to run on the VM during provisioning (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "os_type" {
  description = "Operating system type (Linux or Windows) for NSG rule."
  type        = string
  default     = "Linux"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for VNet and NSG naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "azure_resource_group_name" {
  description = "Name of the existing Azure Resource Group where resources will be deployed."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "Azure Subscription ID for provider configuration and image lookup."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "image_name" {
  description = "The custom image name to use for the VM deployment."
  type        = string
  default     = "ubuntu-22-04-19252758120" # CRITICAL: Specific custom image name as per instructions
}

# ---------------------------------------------------------------------------------------------------------------------
# Data Sources - CRITICAL: Resource Group data source
# ---------------------------------------------------------------------------------------------------------------------

# CRITICAL: Data source to reference the existing Azure Resource Group.
# The resource group is assumed to already exist and will not be created.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# ---------------------------------------------------------------------------------------------------------------------
# SSH Key Pair Generation (Linux deployments only)
# ---------------------------------------------------------------------------------------------------------------------

# Generates a new SSH private key locally for VM access.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 2048
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
}

# ---------------------------------------------------------------------------------------------------------------------
# Azure Networking Setup - CRITICAL: Tenant Isolation and "get-or-create" pattern
# ---------------------------------------------------------------------------------------------------------------------

# 1. CRITICAL: Data Source for VNet (using azurerm_resources to check existence without failing)
# Queries for an existing VNet based on tenant ID.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet" # CRITICAL: Name format based on tenant ID
  # CRITICAL: The 'filter' block is FORBIDDEN for this data source.
}

# 2. CRITICAL: Conditional VNet Creation (only if it doesn't exist)
# Creates a dedicated VNet for the tenant if the query finds no existing VNet.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0 # Conditional creation
  
  name                = "pmos-tenant-${var.tenant_id}-vnet" # CRITICAL: Name format based on tenant ID
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space
}

# 3. CRITICAL: Local Variables for VNet attributes (selects existing or newly created)
# This local block determines whether to use the ID/name of an existing VNet or the newly created one.
locals {
  vnet_id = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? (
    data.azurerm_resources.existing_vnet_query.resources[0].id
  ) : (
    azurerm_virtual_network.tenant_vnet[0].id
  )
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? (
    data.azurerm_resources.existing_vnet_query.resources[0].name
  ) : (
    azurerm_virtual_network.tenant_vnet[0].name
  )
}

# 4. CRITICAL: Subnet Creation for THIS deployment
# Generates a random integer for the third octet of the subnet address prefix to avoid conflicts.
resource "random_integer" "subnet_octet" {
  min = 2  # Start from 2 to avoid conflicts with common gateway IPs
  max = 254
}

# Creates a new subnet specifically for this VM deployment within the selected VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet" # CRITICAL: Unique name based on instance name
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name # Associates with the selected VNet
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"] # Dynamic address prefix
  # CRITICAL: The 'azurerm_subnet' resource does NOT support a 'tags' argument.
}

# 5. CRITICAL: Get-or-Create NSG (Network Security Group)
# Queries for an existing NSG based on tenant ID.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg" # CRITICAL: Name format based on tenant ID
  # CRITICAL: The 'filter' block is FORBIDDEN for this data source.
}

# Conditionally creates an NSG for the tenant if it doesn't already exist.
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0 # Conditional creation
  
  name                = "pmos-tenant-${var.tenant_id}-nsg" # CRITICAL: Name format based on tenant ID
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL: Security rule to allow SSH (for Linux) or RDP (for Windows)
  security_rule {
    name                       = var.os_type == "Linux" ? "AllowSSH" : "AllowRDP" # Rule name based on OS type
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = var.os_type == "Linux" ? "22" : "3389" # Destination port based on OS type
    source_address_prefix      = "Internet" # Allow access from any IP
    destination_address_prefix = "*"
  }
}

# Local variable for NSG ID (selects existing or newly created NSG)
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? (
    data.azurerm_resources.existing_nsg_query.resources[0].id
  ) : (
    azurerm_network_security_group.tenant_nsg[0].id
  )
}

# 6. CRITICAL: Associate Subnet and NSG
# Associates the newly created subnet with the selected (existing or newly created) Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL NETWORKING REQUIREMENT: Creates a Standard SKU Public IP address for the VM.
# This is required for management agents (e.g., Azure Arc) and general external connectivity.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"  # CRITICAL: Must be Static
  sku                 = "Standard"  # CRITICAL: Must be Standard
}

# Network Interface for the VM, associating it with the subnet and public IP.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.this_subnet.id # CRITICAL: Link to newly created subnet
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Virtual Machine Deployment
# ---------------------------------------------------------------------------------------------------------------------

# Deploys an Azure Linux Virtual Machine.
resource "azurerm_linux_virtual_machine" "this_vm" { # CRITICAL: Resource name "this_vm"
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser" # CRITICAL: Must be "azureuser"
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # SSH Key for authentication
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Using the specific custom image ID format.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.image_name}"

  # CRITICAL: Custom script (user data) passed via base64 encoding.
  custom_data = base64encode(var.custom_script)

  # CRITICAL: Enable Serial Console for Linux VMs.
  boot_diagnostics {}

  # CRITICAL: The 'enabled' argument is FORBIDDEN for this resource.
}

# ---------------------------------------------------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------------------------------------------------

# CRITICAL: Output block named "private_ip"
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# CRITICAL: Output block named "instance_id"
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# CRITICAL: Output block named "private_ssh_key" and marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}