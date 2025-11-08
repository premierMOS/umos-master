# Configure the Azure provider
# CRITICAL: Disable automatic resource provider registration as required.
# CRITICAL: Use the subscription_id variable for authentication.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true # Required for this deployment environment
}

# Declare the subscription_id variable.
# CRITICAL: This variable is required by the provider configuration.
variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# CRITICAL: Data source to reference the existing Azure Resource Group.
# The resource group 'umos' is assumed to already exist.
data "azurerm_resource_group" "rg" {
  name = "umos"
}

# CRITICAL: Generate an SSH key pair for Linux deployments.
# This key will be used for administrative access to the VM.
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create a Virtual Network for the VM
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.vm_name}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# Create a Subnet within the Virtual Network
resource "azurerm_subnet" "subnet" {
  name                 = "subnet-${var.vm_name}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Create a Network Interface for the VM
resource "azurerm_network_interface" "nic" {
  name                = "nic-${var.vm_name}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# CRITICAL: Deploy the Linux Virtual Machine.
# The primary compute resource MUST be named "this_vm".
# CRITICAL: The azurerm_linux_virtual_machine resource does NOT support a top-level 'enabled' argument.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                = var.vm_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = var.admin_username
  disable_password_authentication = true

  # CRITICAL: Attach the generated SSH public key.
  admin_ssh_key {
    username  = var.admin_username
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    name                 = "${var.vm_name}-osdisk"
  }

  # CRITICAL: Use the specified custom image ID.
  # The source_image_id must be in the correct format including subscription_id and resource group.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-20-04-19184182442"

  # Attach custom data script if provided.
  custom_data = base64encode(var.custom_script)

  tags = {
    environment = "dev"
  }
}

# Output the private IP address of the created VM.
# CRITICAL: The output block MUST be named "private_ip".
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.private_ip_address
}

# Output the generated private SSH key.
# CRITICAL: The output block MUST be named "private_ssh_key" and marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key generated for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}

# Input variables from the JSON configuration
variable "vm_name" {
  description = "The name of the virtual machine."
  type        = string
  default     = "test-tenant-3"
}

variable "vm_size" {
  description = "The size of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "custom_script" {
  description = "User data script for the virtual machine."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "admin_username" {
  description = "The administrator username for the VM."
  type        = string
  default     = "azureuser" # Standard practice for Linux VMs on Azure
}