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

# Configure the AzureRM Provider
# CRITICAL: Disables automatic resource provider registration as per instructions.
# CRITICAL: Uses the 'subscription_id' variable for configuration.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true # CRITICAL: Required for this environment
}

# Declares a variable for the Azure Subscription ID
# CRITICAL: Default value taken from the JSON configuration.
variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33" # From JSON: azure_subscription_id
}

# Local variables for common naming and configuration values
locals {
  instance_name     = "test-tenant-2"               # From JSON: platform.instanceName
  vm_size           = "Standard_B1s"                # From JSON: platform.vmSize
  custom_image_name = "ubuntu-20-04-19184182442"    # CRITICAL: Actual Cloud Image Name provided
  admin_username    = "azureuser"
}

# CRITICAL: Data source to reference an existing Azure Resource Group.
# FORBIDDEN: Do not create a new resource group.
# Name MUST be "rg" as per instructions.
data "azurerm_resource_group" "rg" {
  name = "umos" # From JSON: azure_resource_group
}

# CRITICAL: Generates a new SSH private key for administrative access.
# Name MUST be "admin_ssh" as per instructions.
# CRITICAL: The 'comment' argument is FORBIDDEN for this resource.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Resource: Azure Virtual Network
# Deploys a new virtual network within the specified resource group.
resource "azurerm_virtual_network" "vnet" {
  name                = "${local.instance_name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Resource: Azure Subnet
# Deploys a subnet within the virtual network.
resource "azurerm_subnet" "subnet" {
  name                 = "${local.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Resource: Azure Network Security Group (NSG)
# Creates an NSG and a rule to allow SSH (port 22) traffic.
resource "azurerm_network_security_group" "nsg" {
  name                = "${local.instance_name}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# Resource: Azure Network Interface (NIC)
# Creates a network interface for the virtual machine, associating it with the subnet and NSG.
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

# Resource: Associate NSG to Subnet
# Links the created Network Security Group to the subnet.
resource "azurerm_subnet_network_security_group_association" "nsg_association" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# CRITICAL: Deploys the Azure Linux Virtual Machine.
# Name MUST be "this_vm" as per instructions.
# CRITICAL: The 'enabled' argument is FORBIDDEN for this resource.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                = local.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = local.vm_size
  admin_username      = local.admin_username
  disable_password_authentication = true

  # CRITICAL: Configure SSH access using the generated public key.
  # Uses 'tls_private_key.admin_ssh.public_key_openssh' as per instructions.
  admin_ssh_key {
    username   = local.admin_username
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size for OS
  }

  # CRITICAL: Specifies the pre-built custom image.
  # Source Image ID MUST be formatted as per instructions, using the `subscription_id` variable
  # and the `data.azurerm_resource_group.rg` data source.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${local.custom_image_name}"
}


# CRITICAL: Output block for the private IP address of the VM.
# Name MUST be "private_ip" as per instructions.
# Value MUST be 'azurerm_linux_virtual_machine.this_vm.private_ip_address'.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.private_ip_address
}

# CRITICAL: Output block for the generated private SSH key.
# Name MUST be "private_ssh_key" as per instructions.
# Value MUST be 'tls_private_key.admin_ssh.private_key_pem' and marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key for accessing the virtual machine. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}