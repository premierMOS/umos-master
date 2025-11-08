# Azure Provider Configuration
# CRITICAL: Disables automatic resource provider registration to prevent permissions errors.
# The service principal used in the CI/CD environment does not have the necessary permissions.
provider "azurerm" {
  subscription_id            = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33" # From JSON config: azure_subscription_id
  skip_provider_registration = true                                   # Required for specific CI/CD environment
  features {}
}

# Data Source for Existing Azure Resource Group
# CRITICAL: The resource group "umos" is assumed to already exist.
# We are forbidden from creating it and must use a data source to reference it.
data "azurerm_resource_group" "rg" {
  name = "umos" # From JSON config: azure_resource_group
}

# Generate an SSH key pair for Linux deployments
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create a Virtual Network for the VM
resource "azurerm_virtual_network" "this_vnet" {
  name                = "vnet-${data.azurerm_resource_group.rg.name}-${random_string.suffix.result}"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Create a Subnet within the Virtual Network
resource "azurerm_subnet" "this_subnet" {
  name                 = "subnet-${data.azurerm_resource_group.rg.name}-${random_string.suffix.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.this_vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Create a Public IP Address for the VM
resource "azurerm_public_ip" "this_public_ip" {
  name                = "public-ip-${data.azurerm_resource_group.rg.name}-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Create a Network Security Group to allow SSH access
resource "azurerm_network_security_group" "this_nsg" {
  name                = "nsg-${data.azurerm_resource_group.rg.name}-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "0.0.0.0/0" # Allow SSH from any IP (for testing)
    destination_address_prefix = "*"
  }
}

# Create a Network Interface for the VM
resource "azurerm_network_interface" "this_nic" {
  name                = "nic-${data.azurerm_resource_group.rg.name}-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_public_ip.id
  }
}

# Associate the Network Security Group with the Network Interface
resource "azurerm_network_interface_security_group_association" "this_nic_nsg_association" {
  network_interface_id      = azurerm_network_interface.this_nic.id
  network_security_group_id = azurerm_network_security_group.this_nsg.id
}

# Deploy the Azure Linux Virtual Machine
# CRITICAL: The primary compute resource MUST be named "this_vm".
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                = "test-tenant-1" # From JSON config: platform.instanceName
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = "Standard_B1s" # From JSON config: platform.vmSize

  # CRITICAL: The 'azurerm_linux_virtual_machine' resource does NOT support a top-level 'enabled' argument.
  # FORBIDDEN from adding 'enabled = false' or any 'enabled' argument directly within this resource block.

  admin_username = "packer" # Common admin user for custom cloud images

  # CRITICAL: For Azure, the 'admin_ssh_key' block MUST use the 'public_key_openssh' attribute.
  admin_ssh_key {
    username   = "packer"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  network_interface_ids = [azurerm_network_interface.this_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size
  }

  # CRITICAL: Use the actual cloud image name 'ubuntu-20-04-19184182442'
  # Construct the source_image_id as a managed image within the specified resource group.
  source_image_id = "/subscriptions/${azurerm_provider.azurerm.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-20-04-19184182442"

  # User data script (from JSON config), base64 encoded for Azure custom_data
  # The comment in the JSON indicates direct deployment support limitations, but we include it if provided.
  custom_data = base64encode(
    "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  )
}

# Add a random suffix to resource names to avoid conflicts
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
  numeric = true
}

# Output the private IP address of the virtual machine
# CRITICAL: Output block MUST be named "private_ip".
output "private_ip" {
  value       = azurerm_linux_virtual_machine.this_vm.private_ip_address
  description = "The private IP address of the deployed virtual machine."
}

# Output the generated private SSH key
# CRITICAL: Output block MUST be named "private_ssh_key" and marked as sensitive.
output "private_ssh_key" {
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
  description = "The private SSH key for accessing the VM. Keep this secure!"
}

# Output the Public IP address of the virtual machine for convenience
output "public_ip" {
  value       = azurerm_public_ip.this_public_ip.ip_address
  description = "The public IP address of the deployed virtual machine."
}