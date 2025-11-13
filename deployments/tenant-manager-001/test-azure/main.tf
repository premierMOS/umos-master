# Configure the Azure Provider
# This block specifies the Azure provider and its configuration.
# We explicitly set the subscription ID and skip provider registration
# as required by the environment's service principal permissions.
provider "azurerm" {
  features {} # Required for newer versions of azurerm provider
  subscription_id = var.subscription_id
  # Required to prevent permissions errors in CI/CD environment
  # when the service principal lacks permissions to register providers.
  skip_provider_registration = true
}

# Declare Terraform variables for key configuration values.
# Each variable includes a 'default' value directly from the provided JSON,
# preventing interactive prompts during execution.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azure"
}

variable "region" {
  description = "The Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size/SKU of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A base64-encoded custom script to run on VM startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "subscription_id" {
  description = "The Azure subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "resource_group_name" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "os_image_name" {
  description = "The exact name of the custom OS image to use."
  type        = string
  # CRITICAL: Use the exact cloud image name provided, not the friendly name.
  default     = "ubuntu-22-04-19340995664"
}

# Data source to reference the existing Azure Resource Group.
# The resource group is assumed to exist and is not created by this script.
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# Generate an SSH key pair for administrative access to the VM.
# This private key will be used for SSH login.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # The 'comment' argument is forbidden for tls_private_key resource.
}

# Data source to check for an existing Virtual Network (VNet) for the tenant.
# This implements the "get-or-create" pattern for VNet tenant isolation.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create a new Virtual Network (VNet) if it doesn't already exist.
# This ensures each tenant has a dedicated and isolated VNet.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space
}

# Data source to check for an existing Network Security Group (NSG) for the tenant.
# This implements the "get-or-create" pattern for NSG tenant isolation.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create a new Network Security Group (NSG) if it doesn't already exist.
# This ensures each tenant has a dedicated and isolated NSG.
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH from Azure's infrastructure for management.
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
}

# Local variables to select the correct VNet and NSG attributes based on
# whether they were found (data source) or created (resource).
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# Create a new subnet specifically for this virtual machine deployment.
# It is associated with the selected VNet (existing or newly created).
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.1.0/24"] # Example, ensure unique in VNet space
}

# Associate the newly created subnet with the tenant's Network Security Group (NSG).
# This ensures all VMs in this subnet inherit the tenant-level network security rules.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Public IP Address for the virtual machine.
# This enables outbound connectivity for management agents (e.g., Azure diagnostics)
# and inbound SSH access (if allowed by NSG).
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Basic" # Basic SKU is sufficient for general VM use cases
}

# Create a Network Interface Card (NIC) for the virtual machine.
# It connects the VM to the subnet and associates the public IP.
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

  # CRITICAL: The NSG association is handled via azurerm_subnet_network_security_group_association,
  # so 'network_security_group_id' is explicitly forbidden here.
}

# Deploy the Azure Linux Virtual Machine.
# This resource uses the specified VM size, custom OS image, network interface,
# SSH key, and optional custom script.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  size                            = var.vm_size
  admin_username                  = "azureuser" # Standard admin username for Linux VMs

  # Attach the generated SSH public key for secure access.
  admin_ssh_key {
    username = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  network_interface_ids = [azurerm_network_interface.this_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size
  }

  # Use the custom image ID constructed from subscription, resource group, and image name.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  # Pass the custom script as base64 encoded custom data.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # CRITICAL: The 'enabled' argument is not supported for this resource type.
}

# Output the private IP address of the virtual machine.
# This is useful for internal network communication.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
# This ID uniquely identifies the VM within Azure.
output "instance_id" {
  description = "The Azure ID of the deployed virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key.
# This output is marked as sensitive to prevent it from being displayed
# in plaintext in Terraform logs.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}