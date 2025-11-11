# Configure the Azure provider
# This block specifies the Azure subscription to deploy resources into and
# disables automatic resource provider registration as per environment requirements.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true # CRITICAL: Required for this CI/CD environment to prevent permissions errors
}

# Terraform variables for key configuration values, with defaults from the JSON input.
# These variables make the script flexible and prevent interactive prompts.
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
  description = "The unique identifier for the tenant, used for resource naming and isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to be executed on the VM after provisioning (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "subscription_id" {
  description = "The Azure subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "azure_resource_group_name" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "os_image_name" {
  description = "The exact name of the custom OS image in Azure Compute Gallery."
  type        = string
  default     = "ubuntu-22-04-19252758120" # CRITICAL: Explicitly provided image name
}

# Data source to look up the existing Azure Resource Group.
# The resource group is assumed to exist and is not created by this script.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# Resource to generate an SSH private key for administrative access.
# The 'comment' argument is explicitly forbidden.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Data source to look for an existing Virtual Network (VNet) for the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create a new Virtual Network (VNet) for the tenant.
# It is created only if the 'existing_vnet' data source lookup fails (i.e., returns no ID).
resource "azurerm_virtual_network" "tenant_vnet" {
  # CRITICAL: `count` for conditional creation based on `existing_vnet` lookup
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space for the VNet

  tags = {
    tenantId = var.tenant_id
  }
}

# Local variables to select the correct VNet attributes (either existing or newly created).
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
}

# Create a new subnet for this specific deployment within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name # Associate with the selected VNet
  address_prefixes     = ["10.0.1.0/24"]  # Example subnet address prefix
}

# Data source to look for an existing Network Security Group (NSG) for the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create a new Network Security Group (NSG) for the tenant.
# It is created only if the 'existing_nsg' data source lookup fails.
resource "azurerm_network_security_group" "tenant_nsg" {
  # CRITICAL: `count` for conditional creation based on `existing_nsg` lookup
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL: Security rule to allow SSH from Azure's infrastructure for management
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
    tenantId = var.tenant_id
  }
}

# Local variable to select the correct NSG ID (either existing or newly created).
locals {
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# Associate the newly created subnet with the tenant's NSG.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL NETWORKING: Create a Public IP address for the VM.
# This ensures connectivity for management agents like AWS SSM (or Azure equivalents).
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Dynamic" # Dynamic allocation, cost-effective for ephemeral IPs
  sku                 = "Basic"
  tags = {
    instanceName = var.instance_name
    tenantId     = var.tenant_id
  }
}

# Create a Network Interface for the virtual machine.
# This attaches the VM to the subnet and associates the public IP.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id # CRITICAL: Associate with the created subnet
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id # CRITICAL: Associate the public IP
  }

  tags = {
    instanceName = var.instance_name
    tenantId     = var.tenant_id
  }
}

# Deploy the Azure Linux Virtual Machine.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                  = var.instance_name
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = data.azurerm_resource_group.rg.location
  size                  = var.vm_size
  admin_username        = "azureuser" # Standard admin username for Linux VMs
  network_interface_ids = [azurerm_network_interface.this_nic.id]
  disable_password_authentication = true # Ensure only SSH key access

  # CRITICAL: Attach the generated SSH public key for admin access.
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # CRITICAL: Specify the custom image ID.
  # The format is specific for custom images in Azure.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default OS disk size, adjust as needed
  }

  # CRITICAL: Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # Pass the custom script as user data.
  custom_data = base64encode(var.custom_script)

  tags = {
    instanceName = var.instance_name
    tenantId     = var.tenant_id
  }

  # CRITICAL: The 'azurerm_linux_virtual_machine' resource does NOT support a top-level 'enabled' argument.
}

# Output the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the created virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key, marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key for accessing the virtual machine."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}