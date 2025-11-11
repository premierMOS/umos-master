# Configure the Azure provider
# Skip provider registration to prevent permissions errors in CI/CD environments.
# The features block is required but can be empty for most use cases.
provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id            = var.subscription_id
}

# Configure the TLS provider for generating SSH keys
provider "tls" {}

# Configure the Random provider for generating unique values
provider "random" {}

# Declare Terraform variables with default values pulled directly from the JSON configuration.
# This ensures the script is non-interactive and ready to deploy.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azurei-2"
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
  description = "A base64 encoded custom script to be executed on the VM after provisioning."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "subscription_id" {
  description = "The Azure subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

# Look up the existing Azure Resource Group where resources will be deployed.
# This data source assumes the resource group has been pre-created.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Generate a new SSH private key for administrative access to the VM.
# The comment argument is intentionally omitted as per instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Look for an existing Virtual Network (VNet) for the tenant.
# This data source will return an empty list if no matching VNet is found, preventing failures.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# Conditionally create the Virtual Network (VNet) if it does not already exist.
# The count meta-argument ensures creation only when the data source returns no resources.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space for the VNet
}

# Local variables to abstract the VNet ID and name,
# choosing between the existing VNet or the newly created one.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
}

# Generate a random integer for the third octet of the subnet address prefix.
# This helps ensure unique subnet address spaces within the VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a dedicated subnet for this VM deployment within the chosen VNet.
# The name includes the instance name for uniqueness.
# Tags are explicitly forbidden on azurerm_subnet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Look for an existing Network Security Group (NSG) for the tenant.
# This data source will return an empty list if no matching NSG is found.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}

# Conditionally create the Network Security Group (NSG) if it does not already exist.
# Includes a security rule to allow SSH access for Linux VMs.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow inbound SSH (port 22) from any source for Linux VMs.
  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "22"
  }
}

# Local variable to abstract the NSG ID, choosing between the existing NSG or the newly created one.
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? data.azurerm_resources.existing_nsg_query.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Associate the created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Standard SKU Public IP address for the VM to ensure external connectivity.
# This is required for management agents and prevents IP exhaustion with Basic SKU.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: Must be Standard SKU
}

# Create a Network Interface for the virtual machine.
# The network security group is associated with the subnet, not directly with the NIC.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id # Associate public IP
  }
}

# Deploy the Azure Linux Virtual Machine.
# Uses a custom image ID and attaches the generated SSH key.
# User data is passed via custom_data, and boot diagnostics are enabled.
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

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120" # CRITICAL: Custom image ID provided

  # Pass custom script as base64 encoded custom_data
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access
  boot_diagnostics {}
}

# Output the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine within Azure."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key. Marked as sensitive to prevent display in logs.
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}