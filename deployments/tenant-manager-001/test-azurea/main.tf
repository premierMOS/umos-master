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

provider "azurerm" {
  features {}
  # CRITICAL: Disable automatic resource provider registration as per instructions.
  # This is required for the service principal in this environment.
  skip_provider_registration = true
  subscription_id            = var.subscription_id
}

# Terraform Variables for key configuration values, with defaults from JSON.
variable "instance_name" {
  type        = string
  description = "The name of the virtual machine instance."
  default     = "test-azurea"
}

variable "region" {
  type        = string
  description = "The Azure region where resources will be deployed."
  default     = "East US"
}

variable "vm_size" {
  type        = string
  description = "The size of the virtual machine."
  default     = "Standard_B1s"
}

variable "tenant_id" {
  type        = string
  description = "The unique identifier for the tenant, used for resource naming."
  default     = "tenant-manager-001"
}

variable "custom_script" {
  type        = string
  description = "A custom script to execute on the VM upon first boot."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  type        = string
  description = "The name of the existing Azure Resource Group."
  default     = "umos"
}

variable "subscription_id" {
  type        = string
  description = "The Azure Subscription ID for deployment."
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# CRITICAL: Use a data source to reference the existing Azure Resource Group.
# The resource group is assumed to already exist.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Generate an SSH key pair for administrative access to the Linux VM.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'comment' argument is forbidden for 'tls_private_key'.
}

# CRITICAL: Data source to check for an existing tenant-specific Virtual Network (VNet).
# This prevents cyclic dependencies by not referencing 'locals' variables directly.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# CRITICAL: Conditionally create the tenant-specific Virtual Network (VNet).
# This VNet is dedicated to the tenant for isolation.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space
}

# Locals block to select the VNet ID and name, whether it was existing or newly created.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
}

# CRITICAL: Generate a random octet for dynamic subnet creation.
# This ensures unique, non-overlapping subnets for each deployment within the VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# CRITICAL: Create a unique subnet for this VM within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # CRITICAL: Dynamic /24 subnet address within the 10.0.0.0/16 space.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# CRITICAL: Data source to check for an existing tenant-specific Network Security Group (NSG).
# This prevents cyclic dependencies by not referencing 'locals' variables directly.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# CRITICAL: Conditionally create the tenant-specific Network Security Group (NSG).
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL: Security rule to allow SSH from Azure's infrastructure.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "AzureCloud" # Allows SSH from Azure's management plane
    destination_address_prefix = "*"
  }
}

# Locals block to select the NSG ID, whether it was existing or newly created.
locals {
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# CRITICAL: Associate the newly created subnet with the selected NSG.
# This is the mandated method for NSG association to ensure tenant isolation.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL: Create a Standard SKU Public IP address for the VM.
# This is required for management agents like Azure Arc/SSM to connect.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: Standard SKU required
}

# Create a Network Interface for the VM.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    private_ip_address_allocation = "Dynamic"
    # CRITICAL: Associate with the dynamically created subnet.
    subnet_id                     = azurerm_subnet.this_subnet.id
    # Associate the Public IP with the Network Interface.
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }

  # CRITICAL: FORBIDDEN from adding 'network_security_group_id' here.
  # NSG association is done via 'azurerm_subnet_network_security_group_association'.
}

# Deploy the Linux Virtual Machine.
resource "azurerm_linux_virtual_machine" "this_vm" {
  # CRITICAL: Primary compute resource MUST be named "this_vm".
  name                = var.instance_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = "azureuser" # Standard admin username for Azure Linux VMs

  # Attach the Network Interface to the VM.
  network_interface_ids = [azurerm_network_interface.this_nic.id]

  # Configure the OS Disk.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size
  }

  # CRITICAL: Use the exact custom image ID as specified.
  # This uses the specific custom image built by the CI/CD pipeline.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19340995664"

  # CRITICAL: Attach the generated SSH public key for admin access.
  admin_ssh_key {
    username  = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # CRITICAL: Pass the custom script as base64 encoded custom_data.
  custom_data = base64encode(var.custom_script)

  # CRITICAL: Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # Disable password authentication for security, relying on SSH keys.
  disable_password_authentication = true

  # CRITICAL: The 'enabled' argument is forbidden for azurerm_linux_virtual_machine.
}

# Output the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The Azure ID of the deployed virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key.
# CRITICAL: This output MUST be marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key generated for the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}