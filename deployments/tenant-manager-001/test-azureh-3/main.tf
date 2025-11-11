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

provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id            = var.subscription_id
}

# Terraform Variables for key configuration values
# These variables provide default values directly from the JSON configuration,
# preventing interactive prompts during `terraform plan` or `terraform apply`.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azureh-3"
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
  description = "The unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to be executed on the VM after provisioning."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "os_type" {
  description = "The operating system type of the VM (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "image_name" {
  description = "The name of the custom OS image to use for the VM."
  type        = string
  default     = "ubuntu-22-04-19252758120"
}

# Data source to reference the existing Azure Resource Group
# This avoids creating a new resource group and leverages an existing one.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Generate an SSH key pair for secure access to the Linux VM.
# The 'comment' argument is forbidden as per critical instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Data source to query for an existing Virtual Network (VNet) for the tenant.
# This allows for a "get-or-create" pattern, ensuring tenant isolation.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# Conditionally create a new Virtual Network if one doesn't already exist for the tenant.
# This ensures each tenant has a dedicated VNet.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Data source to query for an existing Network Security Group (NSG) for the tenant.
# This also allows for a "get-or-create" pattern.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}

# Conditionally create a new Network Security Group if one doesn't already exist for the tenant.
# Includes an inbound rule for SSH (Linux) or RDP (Windows).
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                       = var.os_type == "Linux" ? "AllowSSH" : "AllowRDP"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = var.os_type == "Linux" ? "22" : "3389"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# Local variables to select the correct VNet and NSG attributes based on whether they were created or found.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? data.azurerm_resources.existing_nsg_query.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Generate a random integer for a unique subnet octet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a dedicated subnet for this VM deployment within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
  # Tags are explicitly forbidden on azurerm_subnet by critical instructions.
}

# Associate the newly created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Standard SKU Public IP address for the VM.
# Required for management agent connectivity in public subnets, even if no inbound rules.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: Must be Standard SKU.
}

# Create a Network Interface for the VM.
# This connects the VM to the subnet and associates the public IP and NSG.
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

  network_security_group_id = local.nsg_id
}

# Deploy the Azure Linux Virtual Machine.
# Uses the specified custom image and attaches to the created network resources.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  size                            = var.vm_size
  admin_username                  = "azureuser" # CRITICAL: Must be "azureuser"
  network_interface_ids           = [azurerm_network_interface.this_nic.id]
  disable_password_authentication = true

  admin_ssh_key {
    username  = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # CRITICAL: Use the exact provided image name and format for source_image_id.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.image_name}"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  # Apply custom script as base64 encoded custom data.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # The 'enabled' argument is forbidden as per critical instructions.
}

# Output the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key. Marked as sensitive to prevent display in logs.
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}