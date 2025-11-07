terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# --- Azure Provider Configuration ---
# CRITICAL: Disables automatic resource provider registration as required for the CI/CD environment.
provider "azurerm" {
  subscription_id = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33" # Using azure_subscription_id from configuration
  skip_provider_registration = true
  features {}
}

# --- Local Variables from JSON Configuration ---
# These variables extract relevant values from the provided JSON to improve readability and maintainability.
locals {
  instance_name         = "test-35"
  region                = "East US"
  vm_size               = "Standard_B1s"
  azure_resource_group  = "umos"
  azure_subscription_id = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
  image_name            = "ubuntu-20-04-19184182442" # Actual Cloud Image Name as specified
}

# --- Data Source: Existing Azure Resource Group ---
# CRITICAL: This data source looks up the existing resource group 'umos'.
# We are FORBIDDEN from creating a new resource group.
data "azurerm_resource_group" "rg" {
  name = local.azure_resource_group
}

# --- Resource: Generate SSH Key Pair for Admin Access ---
# Generates an RSA private and public key pair for SSH access to the VM.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Resource: Azure Virtual Network (VNet) ---
# Creates a new Virtual Network for the VM if one isn't specified as existing.
resource "azurerm_virtual_network" "vnet" {
  name                = "${local.instance_name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

# --- Resource: Azure Subnet ---
# Creates a subnet within the virtual network.
resource "azurerm_subnet" "subnet" {
  name                 = "${local.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# --- Resource: Azure Network Interface ---
# Creates a network interface for the virtual machine.
resource "azurerm_network_interface" "nic" {
  name                = "${local.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# --- Resource: Azure Linux Virtual Machine ---
# Deploys a Linux virtual machine using the specified custom image and configuration.
# CRITICAL: Named "this_vm" as per instructions.
# CRITICAL: No 'enabled' argument as it's not supported at the top level for Azure VMs.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = local.instance_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  size                            = local.vm_size
  admin_username                  = "packer" # Consistent with common image builder patterns
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.nic.id]

  # CRITICAL: Constructing source_image_id for the custom image.
  source_image_id = "/subscriptions/${local.azure_subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${local.image_name}"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  # CRITICAL: Attaches the generated SSH public key for admin access.
  admin_ssh_key {
    username   = "packer" # Use the same admin username as above
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # Note: The 'customScript' from the JSON is explicitly marked as "not yet supported for direct deployment", so it's omitted here.
}

# --- Output: Private IP Address of the VM ---
# CRITICAL: Exposes the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.private_ip_address
}

# --- Output: Private SSH Key ---
# CRITICAL: Exposes the generated private SSH key. Marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key generated for admin access to the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}