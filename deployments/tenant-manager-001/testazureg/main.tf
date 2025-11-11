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

# Configure the Microsoft Azure Provider
# CRITICAL: Disabling automatic provider registration and including an empty features block
# is required due to specific CI/CD environment permissions.
provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id            = var.subscription_id
}

# Terraform Variables for key configuration values
# All variables include 'default' values derived directly from the JSON configuration
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "testazureg"
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

variable "custom_script" {
  description = "A custom script to execute on the virtual machine upon launch."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "The unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
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

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

# Look up the existing Azure Resource Group.
# CRITICAL: We are forbidden from creating a new resource group; this data source is mandatory.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# --- Tenant Isolation Networking (Get-or-Create VNet) ---

# Data source to query for an existing Virtual Network (VNet) for the tenant.
# This data source does not fail if no resources are found.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  # CRITICAL: 'name' argument MUST be set as specified, without a filter block.
  name = "pmos-tenant-${var.tenant_id}-vnet"
}

# Conditionally create a new Virtual Network (VNet) if it doesn't already exist.
# The 'count' meta-argument ensures creation only when the data query finds no existing VNet.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    tenant_id = var.tenant_id
  }
}

# Local variables to select the correct VNet ID and name, whether existing or newly created.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
}

# --- Tenant Isolation Networking (Get-or-Create NSG) ---

# Data source to query for an existing Network Security Group (NSG) for the tenant.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  # CRITICAL: 'name' argument MUST be set as specified, without a filter block.
  name = "pmos-tenant-${var.tenant_id}-nsg"
}

# Conditionally create a new Network Security Group (NSG) if it doesn't already exist.
# The 'count' meta-argument ensures creation only when the data query finds no existing NSG.
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow remote access based on OS type (SSH for Linux, RDP for Windows).
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

  tags = {
    tenant_id = var.tenant_id
  }
}

# Local variable to select the correct NSG ID, whether existing or newly created.
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? data.azurerm_resources.existing_nsg_query.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Generate a random integer for a unique subnet address prefix.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a new subnet for this specific deployment within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # Dynamically construct a unique address prefix using the random integer.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]

  # CRITICAL: 'tags' argument is not supported on azurerm_subnet.
}

# Associate the newly created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Public IP address for the VM.
# CRITICAL: SKU MUST be "Standard" and allocation method "Static".
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    instance_name = var.instance_name
  }
}

# Create a Network Interface for the VM.
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
    instance_name = var.instance_name
  }
}

# Generate an SSH key pair for administrative access.
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Deploy the Azure Linux Virtual Machine.
# The primary compute resource MUST be named "this_vm".
resource "azurerm_linux_virtual_machine" "this_vm" {
  # CRITICAL: 'enabled' argument is FORBIDDEN directly in this resource block.
  name                            = var.instance_name
  location                        = data.azurerm_resource_group.rg.location
  resource_group_name             = data.azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  network_interface_ids           = [azurerm_network_interface.this_nic.id]
  disable_password_authentication = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Use the specific, complete image ID.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  admin_ssh_key {
    username  = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # Pass custom script as custom_data, base64 encoded.
  custom_data = base64encode(var.custom_script)

  # Enable serial console for Linux VMs.
  boot_diagnostics {}

  tags = {
    instance_name = var.instance_name
    tenant_id     = var.tenant_id
  }
}

# Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key.
# This output MUST be marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}