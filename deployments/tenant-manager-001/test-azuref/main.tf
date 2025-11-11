# Configure the AzureRM Provider
# CRITICAL: Disables automatic resource provider registration to prevent permissions errors
# CRITICAL: Includes an empty features block
provider "azurerm" {
  subscription_id = var.subscription_id
  skip_provider_registration = true
  features {}
}

# Required providers for this configuration
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0" # Ensure compatibility with AzureRM provider features
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

# --- Input Variables ---
# CRITICAL: All key configuration values from JSON declared with default values

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-azuref"
}

variable "region" {
  description = "Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "Size of the virtual machine (e.g., Standard_B1s, Standard_DS1_v2)."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "User data script to execute on VM boot."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
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

# --- Data Sources ---

# CRITICAL AZURE RESOURCE GROUP INSTRUCTION:
# Look up the existing Azure Resource Group. This data source assumes the resource group
# already exists and does not create it.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# 1. Data Source for VNet: Use 'azurerm_resources' to query for an existing VNet.
# This data source does not fail when no resources are found.
data "azurerm_resources" "existing_vnet_query" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  type                = "Microsoft.Network/virtualNetworks"
  # CRITICAL: The 'azurerm_resources' data source does NOT support a 'filter' block.
}

# 5. Get-or-Create NSG: Use 'azurerm_resources' to query for an existing Network Security Group.
data "azurerm_resources" "existing_nsg_query" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
  type                = "Microsoft.Network/networkSecurityGroups"
  # CRITICAL: The 'azurerm_resources' data source does NOT support a 'filter' block.
}

# --- Locals Block for Conditional Resource Attributes ---
# 3. Local Variable for VNet: Selects the correct VNet attributes based on existence.
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

  # Local variable for NSG: Selects the correct NSG ID based on existence.
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? (
    data.azurerm_resources.existing_nsg_query.resources[0].id
  ) : (
    azurerm_network_security_group.tenant_nsg[0].id
  )
}

# --- Resources ---

# 2. Conditional VNet Creation: Creates the VNet ONLY if the query finds no resources.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space for the VNet
}

# 2. Random integer for subnet octet to generate a unique address prefix for the subnet.
resource "random_integer" "subnet_octet" {
  min = 2  # Start from 2 to avoid reserved network addresses
  max = 254 # End at 254 to avoid broadcast address
}

# 4. Subnet Creation: Creates a NEW subnet for THIS deployment.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # CRITICAL: Address prefixes constructed dynamically using the random number
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
  # CRITICAL: The azurerm_subnet resource does NOT support a 'tags' argument.
}

# 5. Get-or-Create NSG: Creates the Network Security Group ONLY if the query finds no resources.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow remote access based on OS type (Linux for SSH)
  security_rule {
    name                       = "AllowSSH" # Rule name based on Linux OS type
    priority                   = 1001       # Priority for the rule
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"       # SSH port for Linux VMs
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# 6. Associate Subnet and NSG: Creates an association between the new subnet and the NSG.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL NETWORKING REQUIREMENT:
# Create a Public IP address for the VM.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  # CRITICAL: SKU for Azure Public IP MUST be "Standard"
  sku                 = "Standard"
  tags = {
    tenant_id    = var.tenant_id
    instanceName = var.instance_name
  }
}

# Create a Network Interface for the Virtual Machine
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    # CRITICAL: ip_configuration.subnet_id set to azurerm_subnet.this_subnet.id
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }
  tags = {
    tenant_id    = var.tenant_id
    instanceName = var.instance_name
  }
}

# FOR LINUX DEPLOYMENTS ONLY: Generate an SSH key pair
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
}

# Deploy the Azure Linux Virtual Machine
# CRITICAL: Primary compute resource MUST be named "this_vm"
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  size                            = var.vm_size
  admin_username                  = "azureuser" # A common default for Azure Linux VMs
  disable_password_authentication = true

  # CRITICAL: For Azure, admin_ssh_key block MUST use public_key from tls_private_key
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size for the OS disk
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Using the exact custom image name provided
  # The source_image_id MUST be formatted as specified
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  # CRITICAL: Enable Serial Console for Linux VMs
  boot_diagnostics {}

  # USER DATA/CUSTOM SCRIPT: Pass custom_script to instance's custom_data
  # For Azure, use custom_data and base64encode()
  custom_data = base64encode(var.custom_script)

  tags = {
    tenant_id    = var.tenant_id
    instanceName = var.instance_name
  }
  # CRITICAL AZURE VM ARGUMENT INSTRUCTION: The 'azurerm_linux_virtual_machine'
  # resource does NOT support a top-level 'enabled' argument.
}

# --- Outputs ---

# CRITICAL: Expose the private IP address of the created virtual machine
output "private_ip" {
  description = "The private IP address of the VM."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# CRITICAL: Expose the cloud provider's native instance ID
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# CRITICAL: Expose the generated private SSH key (marked as sensitive)
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}