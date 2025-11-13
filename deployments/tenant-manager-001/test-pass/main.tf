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
      version = "~> 3.1"
    }
  }
}

# Configure the AzureRM Provider
# The 'skip_provider_registration' argument is set to true to avoid
# attempting to register resource providers, which may not be permitted
# by the service principal used in CI/CD environments.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# Terraform variables for key configuration values, with default values
# directly from the provided JSON configuration.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-pass"
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
  description = "The identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "azure_resource_group_name" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "custom_script" {
  description = "A custom script to be executed on the VM upon first boot."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "os_image_name" {
  description = "The exact name of the custom OS image to use."
  type        = string
  default     = "ubuntu-22-04-19340995664"
}

# Data source to look up the existing Azure Resource Group.
# This avoids attempting to create a resource group that already exists.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# Data source to look for an existing Virtual Network for the tenant.
# This prevents recreation if a VNet with the expected name already exists.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the tenant's Virtual Network if it does not exist.
# The 'count' meta-argument checks if the data source found an existing VNet.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    tenant = var.tenant_id
  }
}

# Data source to look for an existing Network Security Group for the tenant.
# This prevents recreation if an NSG with the expected name already exists.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the tenant's Network Security Group if it does not exist.
# Includes a rule to allow SSH from Azure Cloud for management.
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "AzureCloud"
    destination_address_prefix = "*"
  }

  tags = {
    tenant = var.tenant_id
  }
}

# Locals block to select the correct VNet and NSG attributes (ID and name)
# based on whether they were created or looked up.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# Generates a random integer for the third octet of the subnet address.
# This ensures that each VM deployment gets a unique /24 subnet within the VNet,
# preventing address conflicts across deployments.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Creates a new subnet specifically for this virtual machine.
# The subnet name includes the instance name for uniqueness.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # Dynamically assigns a unique /24 address prefix using the random integer.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Associates the newly created subnet with the tenant's Network Security Group.
# This is the required method for NSG association, not directly on the NIC.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Creates a Standard SKU Public IP address for the VM.
# Standard SKU and Static allocation are required for robust deployments.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    tenant = var.tenant_id
  }
}

# Creates a Network Interface Card (NIC) for the VM.
# It is configured to use the unique subnet and the public IP.
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
    tenant = var.tenant_id
  }
}

# Generates a new SSH key pair for the VM's administrator account.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Generates a random password for the VM's administrator account,
# enabling console login in addition to SSH.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
  min_special    = 1
  min_upper      = 1
  min_lower      = 1
  min_numeric    = 1
}

# Deploys the Azure Linux Virtual Machine.
# Named "this_vm" as per instructions.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  location                        = data.azurerm_resource_group.rg.location
  resource_group_name             = data.azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  # Set the admin password using the generated random password.
  admin_password                  = random_password.admin_password.result
  # Disable password authentication to enforce SSH key usage, but also allow console.
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.this_nic.id]

  # Configure the OS disk for the VM.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Specify the custom image to use for the VM.
  # The source_image_id must be in the full ARM path format.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  # Provide the public SSH key for authentication.
  admin_ssh_key {
    username  = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # Pass custom data (user script) to the VM, base64 encoded as required.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for accessing serial console logs.
  boot_diagnostics {}

  tags = {
    tenant = var.tenant_id
  }
}

# Output block to expose the private IP address of the VM.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output block to expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output block to expose the generated private SSH key.
# This output is marked as sensitive to prevent it from being displayed in plaintext in logs.
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}

# Output block to expose the generated admin password.
# This output is marked as sensitive.
output "admin_password" {
  description = "The randomly generated administrator password for the VM."
  value       = random_password.admin_password.result
  sensitive   = true
}