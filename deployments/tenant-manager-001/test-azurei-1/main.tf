# Configure the AzureRM Provider
# Features block and skip_provider_registration are critical for CI/CD environments with restricted permissions.
# The subscription_id is explicitly set to ensure deployment targets the correct Azure subscription.
provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id            = var.subscription_id
}

# Configure the TLS provider for generating SSH keys.
# This is used for Linux virtual machine deployments.
provider "tls" {}

# Configure the Random provider for generating unique values,
# such as a unique octet for subnet address prefixes.
provider "random" {}

# Define input variables for key configuration values,
# with default values populated directly from the provided JSON.

# The desired name for the virtual machine instance.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azurei-1"
}

# The Azure region where resources will be deployed.
variable "region" {
  description = "The Azure region for resource deployment."
  type        = string
  default     = "East US"
}

# The size (SKU) of the virtual machine.
variable "vm_size" {
  description = "The size of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

# Identifier for the tenant, used in naming tenant-specific resources.
variable "tenant_id" {
  description = "The tenant identifier."
  type        = string
  default     = "tenant-manager-001"
}

# Custom script to be executed on the virtual machine upon startup.
# It is base64 encoded before being passed to Azure VMs.
variable "custom_script" {
  description = "Optional custom script for VM user data."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# The name of the existing Azure Resource Group.
# This resource group is assumed to exist and will be looked up.
variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

# The Azure Subscription ID where resources will be deployed.
# Critical for provider configuration.
variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# Data source to retrieve information about the existing Azure Resource Group.
# This avoids attempting to create a resource group that already exists.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Resource to generate a private SSH key for secure access to Linux VMs.
# The 'comment' argument is explicitly omitted as per instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Data source to query for an existing Virtual Network (VNet) for the tenant.
# This implements a "get-or-create" pattern for VNet.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# Conditionally create an Azure Virtual Network (VNet) for the tenant.
# It is created only if no VNet matching the tenant ID is found by the data source.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# Local variables to abstract VNet selection, choosing between existing or newly created.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
}

# Resource to generate a random integer for creating a unique subnet address prefix.
# Ensures that each new subnet has a distinct IP range within the VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a dedicated subnet for this VM deployment within the selected VNet.
# The address prefix uses the random integer to prevent IP conflicts.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
  # Tags are not supported for azurerm_subnet and are explicitly forbidden.
}

# Data source to query for an existing Network Security Group (NSG) for the tenant.
# Implements a "get-or-create" pattern for NSG.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}

# Conditionally create an Azure Network Security Group (NSG) for the tenant.
# It is created only if no NSG matching the tenant ID is found.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH access for Linux VMs.
  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  tags = {
    Environment = "Production"
    Tenant      = var.tenant_id
  }
}

# Local variable to abstract NSG selection, choosing between existing or newly created.
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? data.azurerm_resources.existing_nsg_query.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Associate the newly created subnet with the selected Network Security Group.
# This applies the NSG rules to all resources within the subnet.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Public IP address for the VM.
# CRITICAL: SKU is "Standard" and allocation is "Static" as required.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: Must be Standard
  tags = {
    Environment = "Production"
    Tenant      = var.tenant_id
  }
}

# Create a Network Interface for the VM.
# The NIC is connected to the dedicated subnet and associated with the public IP.
# CRITICAL: The NSG is associated with the SUBNET, not directly with the NIC.
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
    Environment = "Production"
    Tenant      = var.tenant_id
  }
}

# Deploy the Azure Linux Virtual Machine.
# This is the primary compute resource, named "this_vm".
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  size                            = var.vm_size
  admin_username                  = "azureuser" # CRITICAL: Must be "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this_nic.id]

  # SSH public key for the admin user.
  admin_ssh_key {
    username  = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Custom image definition. CRITICAL: Use the exact specified image name.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  # User data/custom script for post-deployment configuration.
  # The script is base64 encoded as required for Azure.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access, CRITICAL for Linux VMs.
  boot_diagnostics {}

  tags = {
    Environment = "Production"
    Tenant      = var.tenant_id
  }
}

# Output the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the Azure-native instance ID of the virtual machine.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key.
# CRITICAL: This output is marked as sensitive to prevent it from being displayed in plain text in logs.
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}