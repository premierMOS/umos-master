# Configure the Azure provider
# CRITICAL: This block includes features {} and skip_provider_registration = true
# to prevent permissions errors during deployment in specific CI/CD environments.
# The subscription_id is set via a variable.
provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id            = var.subscription_id
}

# Configure the TLS provider for generating SSH keys
provider "tls" {}

# Configure the Random provider for generating unique values
provider "random" {}

################################################################################
# Variables
################################################################################

# The desired name for the virtual machine instance.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azureh-2"
}

# The Azure region where resources will be deployed.
variable "region" {
  description = "The Azure region for resource deployment."
  type        = string
  default     = "East US"
}

# The size/SKU of the virtual machine.
variable "vm_size" {
  description = "The size/SKU of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

# Unique identifier for the tenant, used for resource naming and isolation.
variable "tenant_id" {
  description = "Unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

# Custom script to be executed on the VM upon first boot.
# For Azure, this will be passed as custom_data (base64 encoded).
variable "custom_script" {
  description = "Custom script to run on VM startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# The name of the existing Azure Resource Group where resources will be deployed.
variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

# The Azure Subscription ID to deploy resources into.
variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

################################################################################
# Data Sources
################################################################################

# CRITICAL: Lookup the existing Azure Resource Group.
# This data source is used to reference the resource group without creating it.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# CRITICAL: Query for an existing Virtual Network (VNet) for the tenant.
# This data source will be used to implement a "get-or-create" pattern for the VNet.
# The 'name' argument explicitly defines the VNet name to search for.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# CRITICAL: Query for an existing Network Security Group (NSG) for the tenant.
# This data source will be used to implement a "get-or-create" pattern for the NSG.
# The 'name' argument explicitly defines the NSG name to search for.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}

################################################################################
# Locals
################################################################################

locals {
  # CRITICAL: Select the ID of the VNet. If an existing VNet is found, use its ID;
  # otherwise, use the ID of the newly created VNet.
  vnet_id = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ?
    data.azurerm_resources.existing_vnet_query.resources[0].id :
  azurerm_virtual_network.tenant_vnet[0].id

  # CRITICAL: Select the name of the VNet. If an existing VNet is found, use its name;
  # otherwise, use the name of the newly created VNet.
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ?
    data.azurerm_resources.existing_vnet_query.resources[0].name :
  azurerm_virtual_network.tenant_vnet[0].name

  # CRITICAL: Select the ID of the NSG. If an existing NSG is found, use its ID;
  # otherwise, use the ID of the newly created NSG.
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ?
    data.azurerm_resources.existing_nsg_query.resources[0].id :
  azurerm_network_security_group.tenant_nsg[0].id
}


################################################################################
# SSH Key Generation
################################################################################

# CRITICAL: Generate a new SSH private key for administrative access.
# This key will be used to secure the VM's SSH access.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: 'comment' argument is forbidden for tls_private_key.
}

################################################################################
# Azure Networking - Tenant VNet (Get-or-Create)
################################################################################

# CRITICAL: Conditionally create a Virtual Network for the tenant.
# This resource is created only if no existing VNet is found via the data source.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    Environment = "production"
    Tenant      = var.tenant_id
  }
}

# CRITICAL: Generate a random integer for a unique subnet address prefix.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# CRITICAL: Create a new subnet within the tenant's VNet for this deployment.
# The address prefix uses a random octet to minimize IP conflicts.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
  # CRITICAL: The 'azurerm_subnet' resource does NOT support a 'tags' argument.
}

################################################################################
# Azure Networking - Tenant NSG (Get-or-Create)
################################################################################

# CRITICAL: Conditionally create a Network Security Group for the tenant.
# This resource is created only if no existing NSG is found via the data source.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL: Security rule to allow SSH access for Linux VMs.
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
    Environment = "production"
    Tenant      = var.tenant_id
  }
}

# CRITICAL: Associate the newly created subnet with the selected NSG.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

################################################################################
# Azure Networking - Public IP and Network Interface
################################################################################

# CRITICAL: Create a Public IP address for the VM.
# Required for management agents like AWS SSM and general external connectivity.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # CRITICAL: SKU MUST be "Standard".

  tags = {
    Environment = "production"
    Instance    = var.instance_name
  }
}

# Create a Network Interface for the VM.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id # CRITICAL: Use the dynamically created subnet.
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id
  }

  tags = {
    Environment = "production"
    Instance    = var.instance_name
  }
}

################################################################################
# Azure Virtual Machine
################################################################################

# Define the Linux Virtual Machine.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  location                        = data.azurerm_resource_group.rg.location
  resource_group_name             = data.azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = "azureuser" # CRITICAL: admin_username MUST be "azureuser".
  network_interface_ids           = [azurerm_network_interface.this_nic.id]
  disable_password_authentication = true

  # CRITICAL: Use the custom image name provided.
  # The source_image_id must be formatted correctly with subscription and resource group.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  admin_ssh_key {
    username  = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # CRITICAL: Enable boot diagnostics for serial console access on Linux VMs.
  boot_diagnostics {}

  # CRITICAL: Pass the custom script as custom_data (base64 encoded).
  custom_data = base64encode(var.custom_script)

  tags = {
    Environment = "production"
    Instance    = var.instance_name
    Tenant      = var.tenant_id
  }
  # CRITICAL: 'enabled' argument is forbidden for azurerm_linux_virtual_machine.
}

################################################################################
# Outputs
################################################################################

# Expose the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The ID of the virtual machine instance."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Expose the generated private SSH key.
# CRITICAL: This output is marked as sensitive and should be handled securely.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}