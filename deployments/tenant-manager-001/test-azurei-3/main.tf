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
    random = {
      source = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Configure the AzureRM Provider
# CRITICAL: `skip_provider_registration` and `features {}` are mandatory for this environment.
provider "azurerm" {
  subscription_id        = var.subscription_id
  skip_provider_registration = true
  features {}
}

# Declare Terraform variables for key configuration values, with default values from JSON.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azurei-3"
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
  description = "The unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to run on the VM after provisioning."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "resource_group_name_json" {
  description = "The name of the existing Azure Resource Group from the JSON configuration."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# CRITICAL AZURE RESOURCE GROUP INSTRUCTION:
# Assume the Azure Resource Group already exists. Use a data source to reference it.
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name_json
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION INSTRUCTIONS:
# 1. Data Source for VNet: Query for an existing VNet. Does not fail if not found.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  # CRITICAL: The 'name' argument MUST be set as specified. No 'filter' block allowed.
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# 6. Get-or-Create NSG: Query for an existing Network Security Group.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  # CRITICAL: The 'name' argument MUST be set as specified. No 'filter' block allowed.
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}

# Local variables to select the correct VNet and NSG attributes based on existence.
locals {
  # Conditional VNet ID: Use existing if found, otherwise use the newly created one.
  vnet_id = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? (
    data.azurerm_resources.existing_vnet_query.resources[0].id
  ) : (
    azurerm_virtual_network.tenant_vnet[0].id
  )

  # Conditional VNet Name: Use existing if found, otherwise use the newly created one.
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? (
    data.azurerm_resources.existing_vnet_query.resources[0].name
  ) : (
    azurerm_virtual_network.tenant_vnet[0].name
  )

  # Conditional NSG ID: Use existing if found, otherwise use the newly created one.
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? (
    data.azurerm_resources.existing_nsg_query.resources[0].id
  ) : (
    azurerm_network_security_group.tenant_nsg[0].id
  )

  # Derived OS type for conditional logic (e.g., SSH/RDP rule)
  os_type = "Linux" # Hardcoded based on JSON, could be derived from a variable if needed.
}

# 2. Conditional VNet Creation: Create the VNet ONLY if the query finds no resources.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    Name    = "pmos-tenant-${var.tenant_id}-vnet"
    Tenant  = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# Random integer for unique subnet address prefix
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# 4. Subnet Creation: Create a NEW subnet for THIS deployment.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # Use a dynamically generated address prefix to prevent IP conflicts.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]

  # CRITICAL: The 'azurerm_subnet' resource does NOT support a 'tags' argument.
  # FORBIDDEN from adding a 'tags' block to this resource.
}

# 7. Get-or-Create NSG: Create the NSG ONLY if the query finds no resources.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow remote access based on OS type.
  security_rule {
    name                       = local.os_type == "Linux" ? "AllowSSH" : "AllowRDP"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = local.os_type == "Linux" ? "22" : "3389"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  tags = {
    Name    = "pmos-tenant-${var.tenant_id}-nsg"
    Tenant  = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# 8. Associate Subnet and NSG:
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# FOR LINUX DEPLOYMENTS ONLY: Generate an SSH key pair.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
  # FORBIDDEN from including a 'comment' argument in this resource block.
}

# CRITICAL NETWORKING REQUIREMENT FOR AZURE: Create a Standard Public IP.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: MUST be "Standard"

  tags = {
    Name      = "${var.instance_name}-pip"
    Instance  = var.instance_name
    Tenant    = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# 9. Network Interface:
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.this_subnet.id # CRITICAL: Subnet ID from the newly created subnet.
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }

  # CRITICAL: The 'azurerm_network_interface' resource does NOT support a top-level
  # 'network_security_group_id' argument. It is associated with the SUBNET.
  # FORBIDDEN from adding this argument to the NIC.

  tags = {
    Name      = "${var.instance_name}-nic"
    Instance  = var.instance_name
    Tenant    = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# Primary compute resource: Azure Linux Virtual Machine
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                = var.instance_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = "azureuser" # CRITICAL AZURE VM USERNAME INSTRUCTION: MUST be "azureuser"
  network_interface_ids = [azurerm_network_interface.this_nic.id]
  disable_password_authentication = true

  # CRITICAL IMAGE NAME INSTRUCTION: Use the specified custom image name.
  # The 'source_image_id' MUST be formatted as specified.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size, not specified in JSON
  }

  admin_ssh_key {
    username  = "azureuser" # CRITICAL AZURE VM USERNAME INSTRUCTION: MUST be "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # USER DATA/CUSTOM SCRIPT: Pass the custom script as custom_data.
  custom_data = base64encode(var.custom_script)

  # CRITICAL AZURE VM ARGUMENT INSTRUCTION: No top-level 'enabled' argument.

  # Enable Serial Console for Linux VMs.
  boot_diagnostics {}

  tags = {
    Name      = var.instance_name
    Instance  = var.instance_name
    Tenant    = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# Output block exposing the private IP address of the VM.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output block exposing the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output block exposing the generated private SSH key, marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key (PEM format)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}