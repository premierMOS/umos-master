# Configure the Azure provider
# CRITICAL: Disables automatic resource provider registration to prevent permissions errors.
# The 'features {}' block is required even if empty.
provider "azurerm" {
  subscription_id        = var.subscription_id
  skip_provider_registration = true
  features {}
}

# Terraform block to specify required providers and their versions
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
  required_version = ">= 1.0.0"
}

# --- Input Variables ---
# CRITICAL: All key configuration values are declared as variables with default values
# directly from the JSON to prevent interactive prompts.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azured"
}

variable "region" {
  description = "The Azure region where the resources will be deployed."
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
  description = "A base64-encoded custom script to be run on the VM at startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "resource_group_name" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

# CRITICAL IMAGE NAME INSTRUCTION: The exact cloud image name provided.
variable "os_image_name" {
  description = "The name of the custom OS image to use for the VM."
  type        = string
  default     = "ubuntu-22-04-19252758120"
}

variable "admin_username" {
  description = "The administrator username for the VM."
  type        = string
  default     = "azureuser"
}


# --- Resource Group Data Source ---
# CRITICAL: Looks up an existing Azure Resource Group.
# FORBIDDEN from creating a new one.
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# --- SSH Key Generation ---
# Generates a new SSH private key and extracts the public key.
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Virtual Network (VNet) Management for Tenant Isolation ---
# CRITICAL: Implements a "get-or-create" pattern for the VNet.

# Data source to query for an existing VNet for the tenant.
# This data source does not fail if no resources are found.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name

  filter {
    name   = "name"
    values = ["pmos-tenant-${var.tenant_id}-vnet"]
  }
}

# Conditionally create the VNet ONLY if the query finds no existing resources.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    tenantId = var.tenant_id
  }
}

# Local variable to select the correct VNet attributes (either existing or newly created).
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
}

# --- Subnet Creation ---
# Creates a new subnet for THIS deployment within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.1.0/24"]
  # CRITICAL: The azurerm_subnet resource does NOT support a 'tags' argument.
}

# --- Network Security Group (NSG) Management for Tenant Isolation ---
# CRITICAL: Implements a "get-or-create" pattern for the NSG.

# Data source to query for an existing NSG for the tenant.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name

  filter {
    name   = "name"
    values = ["pmos-tenant-${var.tenant_id}-nsg"]
  }
}

# Conditionally create the NSG ONLY if the query finds no existing resources.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL: Security rule based on OS type
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
    tenantId = var.tenant_id
  }
}

# Local variable to select the correct NSG ID (either existing or newly created).
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? (
    data.azurerm_resources.existing_nsg_query.resources[0].id
  ) : (
    azurerm_network_security_group.tenant_nsg[0].id
  )
}

# --- Subnet NSG Association ---
# Associates the newly created subnet with the tenant's NSG.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# --- Public IP Address ---
# CRITICAL: Required for connectivity for management agents like SSM.
# SKU must be "Standard" and allocation method "Static".
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: Must be Standard

  tags = {
    instanceName = var.instance_name
    tenantId     = var.tenant_id
  }
}

# --- Network Interface ---
# Creates the network interface for the VM.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "${var.instance_name}-ipconfig"
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }

  tags = {
    instanceName = var.instance_name
    tenantId     = var.tenant_id
  }
}

# --- Virtual Machine Deployment (Linux) ---
# Deploys the Azure Linux Virtual Machine.
# CRITICAL: Primary compute resource named "this_vm".
resource "azurerm_linux_virtual_machine" "this_vm" {
  count               = var.os_type == "Linux" ? 1 : 0 # Only deploy Linux VM if os_type is Linux
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username
  network_interface_ids = [azurerm_network_interface.this_nic.id]
  disable_password_authentication = true # Always use SSH keys for security

  # CRITICAL: Attach generated SSH public key
  admin_ssh_key {
    username  = var.admin_username
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size
  }

  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  # User Data/Custom Script configuration
  # CRITICAL: Use 'custom_data' and 'base64encode()'
  custom_data = base64encode(var.custom_script)

  # CRITICAL: Enable Serial Console for Linux VMs
  boot_diagnostics {}

  tags = {
    instanceName = var.instance_name
    tenantId     = var.tenant_id
  }
}

# --- Output Blocks ---
# Exposes key information about the deployed VM.

# Exposes the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = azurerm_linux_virtual_machine.this_vm[0].id
}

# Exposes the generated private SSH key.
# CRITICAL: Marked as sensitive to prevent its value from being displayed in logs.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the virtual machine."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}