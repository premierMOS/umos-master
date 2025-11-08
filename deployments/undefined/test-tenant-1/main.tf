# Required Terraform providers
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

# Azure Provider Configuration
# CRITICAL: Disable automatic resource provider registration as required by the environment.
provider "azurerm" {
  subscription_id            = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33" # Using the 'azure_subscription_id' from the JSON config
  skip_provider_registration = true                                # Required for this specific CI/CD environment
  features {}
}

# CRITICAL: Data source for the existing Azure Resource Group.
# The resource group "umos" is assumed to already exist.
# All other resources requiring a resource group name or location MUST reference this data source.
data "azurerm_resource_group" "rg" {
  name = "umos" # Using the 'azure_resource_group' name from the JSON config
}

# Generate an SSH key pair for Linux virtual machines.
# This key will be used for authentication to the 'this_vm'.
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
# Forbidden from including a 'comment' argument here.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Network Components for the VM ---
# A virtual network is required for the virtual machine.
resource "azurerm_virtual_network" "vnet" {
  name                = "${data.azurerm_resource_group.rg.name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

# A subnet within the virtual network for the virtual machine's network interface.
resource "azurerm_subnet" "subnet" {
  name                 = "${data.azurerm_resource_group.rg.name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# A public IP address to allow external access to the VM.
resource "azurerm_public_ip" "this_vm_public_ip" {
  name                = "test-tenant-1-public-ip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

# Network interface for the virtual machine.
resource "azurerm_network_interface" "this_vm_nic" {
  name                = "test-tenant-1-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_vm_public_ip.id
  }
}

# --- Virtual Machine Deployment ---
# CRITICAL: The primary compute resource MUST be named "this_vm".
resource "azurerm_linux_virtual_machine" "this_vm" {
  # Basic VM Configuration
  name                = "test-tenant-1" # Using 'platform.instanceName' from JSON
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = "Standard_B1s" # Using 'platform.vmSize' from JSON
  admin_username      = "azureuser"

  # CRITICAL: The 'azurerm_linux_virtual_machine' resource DOES NOT support a top-level 'enabled' argument.
  # Forbidden from adding 'enabled = false' or any 'enabled' argument directly within this resource block.

  # Network Configuration
  network_interface_ids = [
    azurerm_network_interface.this_vm_nic.id,
  ]

  # Authentication: SSH Key for Linux
  admin_ssh_key {
    username   = "azureuser"
    # CRITICAL: For Azure, the 'admin_ssh_key' block MUST use the 'public_key_openssh' attribute.
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # OS Disk Configuration
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size for the OS disk
  }

  # Image Reference
  # CRITICAL: Construct the 'source_image_id' using subscription, resource group, and the actual cloud image name.
  # Actual Cloud Image Name: 'ubuntu-20-04-19184182442'
  source_image_id = "/subscriptions/c0ddf8f4-14b2-432e-b2fc-dd8456adda33/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-20-04-19184182442"

  # Custom data (startup script)
  # The JSON configuration provides a custom script, which is applied here.
  # It must be base64 encoded for Azure.
  custom_data = base64encode("#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n")
}

# --- Outputs ---
# CRITICAL: Output block named "private_ip" that exposes the private IP address.
output "private_ip" {
  description = "The private IP address of the created virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.private_ip_address
}

# CRITICAL: Output block named "private_ssh_key" that exposes the generated private key.
# This output MUST be marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}

# Optional: Output the public IP address of the virtual machine for external access.
output "public_ip" {
  description = "The public IP address of the created virtual machine."
  value       = azurerm_public_ip.this_vm_public_ip.ip_address
}