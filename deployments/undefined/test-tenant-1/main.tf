terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0" # Specify a suitable version for Azure provider
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Specify a suitable version for TLS provider
    }
  }
}

# Configure the Azure Provider
# CRITICAL: skip_provider_registration = true is required for this environment.
provider "azurerm" {
  subscription_id        = var.azure_subscription_id
  skip_provider_registration = true
  features {}
}

# CRITICAL: Data source for the existing Azure Resource Group
# The resource group specified in the configuration already exists and must be referenced, not created.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# CRITICAL: Generate an SSH key pair for Linux deployments
# This key will be used for administrative access to the VM.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 2048
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
}

# Create a Virtual Network for the VM
resource "azurerm_virtual_network" "vnet" {
  name                = "${data.azurerm_resource_group.rg.name}-vnet"
  address_space       = ["10.0.0.0/16"]
  # CRITICAL: Use data source for location and resource group name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Create a Subnet within the Virtual Network
resource "azurerm_subnet" "subnet" {
  name                 = "${azurerm_virtual_network.vnet.name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Create a Network Interface for the Virtual Machine
resource "azurerm_network_interface" "nic" {
  name                = "${var.instance_name}-nic"
  # CRITICAL: Use data source for location and resource group name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# CRITICAL: Deploy the Azure Linux Virtual Machine, named "this_vm"
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                = var.instance_name
  # CRITICAL: Use data source for resource group name and location
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser" # Standard admin username for Azure Linux VMs

  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  # CRITICAL: Configure SSH access using the generated public key
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default OS disk size
  }

  # CRITICAL: Specify the source image ID for the custom image
  # Image name: 'ubuntu-20-04-19184182442'
  source_image_id = "/subscriptions/${var.azure_subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-20-04-19184182442"

  # Include custom data (user data script)
  # The JSON comment suggests platform limitation, but Terraform itself supports it.
  custom_data = base64encode(var.custom_script)

  # CRITICAL: 'azurerm_linux_virtual_machine' does not support a top-level 'enabled' argument.
}

# CRITICAL: Output block for the private IP address of the VM
output "private_ip" {
  description = "The private IP address of the created virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.private_ip_address
}

# CRITICAL: Output block for the generated private SSH key (marked as sensitive)
output "private_ssh_key" {
  description = "The private SSH key for securely connecting to the virtual machine."
  value     = tls_private_key.admin_ssh.private_key_pem
  sensitive = true
}

# Variables to abstract configuration values from the JSON
variable "azure_subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "azure_resource_group" {
  description = "The name of the Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-tenant-1"
}

variable "vm_size" {
  description = "The size of the virtual machine (e.g., Standard_B1s)."
  type        = string
  default     = "Standard_B1s"
}

variable "custom_script" {
  description = "Custom script to be executed on the virtual machine during provisioning."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}