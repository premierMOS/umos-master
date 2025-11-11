# Configure the Azure provider
# This block specifies the Azure features and the subscription ID to use for deployment.
# The 'features {}' block is required by the AzureRM provider but can be empty for default settings.
# The subscription_id is critical for targeting the correct Azure subscription.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# --- Variables Block ---
# All key configuration values are declared as Terraform variables with default values
# pulled directly from the provided JSON configuration. This ensures the script can run
# without interactive prompts and provides clear parameterization.

variable "instance_name" {
  type        = string
  default     = "test-zurea"
  description = "Name of the virtual machine instance."
}

variable "region" {
  type        = string
  default     = "East US"
  description = "Azure region where resources will be deployed."
}

variable "vm_size" {
  type        = string
  default     = "Standard_B1s"
  description = "Size of the virtual machine."
}

variable "tenant_id" {
  type        = string
  default     = "tenant-manager-001"
  description = "Unique identifier for the tenant, used for resource naming and isolation."
}

variable "azure_resource_group" {
  type        = string
  default     = "umos"
  description = "Name of the pre-existing Azure Resource Group where resources will be deployed."
}

variable "subscription_id" {
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
  description = "Azure Subscription ID for resource deployment. This is used in the provider configuration."
}

variable "custom_script" {
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to be executed on the VM after provisioning. Will be base64 encoded for Azure custom_data."
}

# --- Data Sources ---

# Data source to reference the pre-existing Azure Resource Group.
# This avoids attempting to create a resource group that already exists and retrieves its properties.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Data source to query for an existing Tenant Virtual Network.
# This allows for a "get-or-create" pattern: if the VNet exists, use it; otherwise, create it.
# The 'name' filter ensures tenant-specific isolation.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# Data source to query for an existing Tenant Network Security Group.
# Similar to the VNet, this implements a "get-or-create" pattern for tenant-specific NSGs.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}


# --- Resource: TLS Private Key ---
# Generates a new SSH private key pair. The private key is output as sensitive,
# and the public key is used for VM authentication.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Azure Network Infrastructure ---

# Conditionally creates a new Virtual Network for the tenant if one doesn't already exist.
# The 'count' meta-argument checks if the existing_vnet_query found any resources.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space, can be customized.

  tags = {
    tenant_id = var.tenant_id
  }
}

# Locals block to determine the VNet ID and name to use.
# It selects from the existing VNet (if found) or the newly created VNet.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
}

# Creates a new subnet specifically for this virtual machine deployment.
# It's associated with the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.1.0/24"] # A /24 subnet within the VNet's address space.
}

# Conditionally creates a new Network Security Group (NSG) for the tenant if one doesn't already exist.
# Includes a security rule to allow SSH access for Linux VMs.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow inbound SSH (port 22) from any source ("Internet").
  # This enables remote administration while the NSG ensures isolation.
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
    tenant_id = var.tenant_id
  }
}

# Locals block to determine the NSG ID to use.
# It selects from the existing NSG (if found) or the newly created NSG.
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? data.azurerm_resources.existing_nsg_query.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Associates the newly created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Creates an Azure Public IP address for the VM.
# This ensures external connectivity for management and outbound traffic.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static" # Static ensures the IP doesn't change on VM restart.
  sku                 = "Basic"  # Basic SKU is sufficient for general-purpose VMs.
}

# Creates the Network Interface for the Virtual Machine.
# It connects the VM to the subnet and associates the public IP.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic" # Dynamic private IP within the subnet.
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }

  tags = {
    environment = var.tenant_id
  }
}

# --- Resource: Azure Linux Virtual Machine ---
# Deploys the Azure Linux Virtual Machine with the specified configuration.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  size                            = var.vm_size
  admin_username                  = "azureuser" # Standard admin username for Linux VMs.
  disable_password_authentication = true        # Ensures only SSH key authentication is used.

  # Assigns the network interface to the VM.
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # Configuration for the OS disk.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # Standard HDD locally redundant storage.
  }

  # Custom image definition. The exact cloud image name is used for deployment.
  # This path includes the subscription, resource group, and image name.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  # Provides the public SSH key for authentication.
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # Enables the serial console and boot diagnostics for troubleshooting.
  boot_diagnostics {}

  # Passes the custom script to be executed on the VM using cloud-init.
  # The script is base64 encoded as required by Azure's custom_data field.
  custom_data = base64encode(var.custom_script)

  tags = {
    environment = var.tenant_id
    instance    = var.instance_name
  }
}

# --- Output Block: Private IP Address ---
# Exposes the private IP address of the created virtual machine's primary network interface.
output "private_ip" {
  description = "The private IP address of the deployed VM."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# --- Output Block: Instance ID ---
# Exposes the Azure-specific resource ID of the created virtual machine.
output "instance_id" {
  description = "The Azure resource ID of the deployed VM."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# --- Output Block: Private SSH Key ---
# Exposes the generated private SSH key.
# Marked as sensitive to prevent its value from being displayed in plain text in console output.
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}