terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

# Configure the Azure Provider
# This ensures the correct subscription is targeted and disables automatic resource provider registration
# as required for CI/CD environments.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true # Required for specific environment constraints, even if deprecated
}

# --- Input Variables ---

# Name of the virtual machine instance
variable "instance_name" {
  type        = string
  description = "The name of the virtual machine instance."
  default     = "test2-azure67"
}

# Azure region for deployment
variable "region" {
  type        = string
  description = "The Azure region where the resources will be deployed."
  default     = "East US"
}

# Size of the virtual machine (e.g., Standard_B1s)
variable "vm_size" {
  type        = string
  description = "The size of the virtual machine."
  default     = "Standard_B1s"
}

# Unique identifier for the tenant, used for resource naming and isolation
variable "tenant_id" {
  type        = string
  description = "A unique identifier for the tenant."
  default     = "tenant-manager-001"
}

# Custom script to run after VM deployment (e.g., for application setup)
variable "custom_script" {
  type        = string
  description = "User-provided script to execute on the VM post-deployment."
  default     = "# Enter your post-deployment script here.\n# For Linux, it will be executed via bash.\n# For Windows, it will be executed via PowerShell.\n"
}

# Azure subscription ID where resources will be deployed
variable "subscription_id" {
  type        = string
  description = "The Azure subscription ID."
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# Name of the existing Azure Resource Group
variable "resource_group_name" {
  type        = string
  description = "The name of the existing Azure Resource Group."
  default     = "umos"
}

# --- Local Values ---

locals {
  # For Azure, custom_data expects a base64 encoded string of the script.
  # The raw custom_script variable is used directly here and then encoded when passed to the VM.
  user_data_script = var.custom_script

  # Conditionally determine the Virtual Network ID based on whether an existing VNet was found
  vnet_id = length(data.azurerm_resources.existing_vnet.resources) > 0 ? (
    data.azurerm_resources.existing_vnet.resources[0].id
  ) : (
    azurerm_virtual_network.tenant_vnet[0].id
  )

  # Conditionally determine the Virtual Network Name based on whether an existing VNet was found
  vnet_name = length(data.azurerm_resources.existing_vnet.resources) > 0 ? (
    data.azurerm_resources.existing_vnet.resources[0].name
  ) : (
    azurerm_virtual_network.tenant_vnet[0].name
  )

  # Conditionally determine the Network Security Group ID based on whether an existing NSG was found
  nsg_id = length(data.azurerm_resources.existing_nsg.resources) > 0 ? (
    data.azurerm_resources.existing_nsg.resources[0].id
  ) : (
    azurerm_network_security_group.tenant_nsg[0].id
  )
}

# --- Data Sources ---

# Look up the existing Azure Resource Group by name
# This resource group is assumed to pre-exist and is not created by this script.
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# Robust check for an existing Virtual Network (VNet) for the tenant
# This data source returns an empty list if no VNet is found, allowing for conditional creation.
data "azurerm_resources" "existing_vnet" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# Robust check for an existing Network Security Group (NSG) for the tenant
# This data source returns an empty list if no NSG is found, allowing for conditional creation.
data "azurerm_resources" "existing_nsg" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}

# --- Resources ---

# Generate a random password for the Windows administrator account
resource "random_password" "admin_password" {
  length        = 16
  special       = true
  override_special = "_!@#&"
}

# Generate a random integer for dynamic subnet address allocation
# This prevents subnet address conflicts across multiple deployments within the same VNet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Conditionally create a new Virtual Network (VNet) for the tenant if it does not already exist.
# This ensures each tenant has an isolated network.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    tenant = var.tenant_id
  }
}

# Conditionally create a new Network Security Group (NSG) for the tenant if it does not already exist.
# This NSG provides network-level security and isolation.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH traffic from Azure's infrastructure for management purposes
  security_rule {
    name                         = "AllowSSH_from_AzureCloud"
    priority                     = 1001
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "22"
    source_address_prefix        = "AzureCloud" # Allows SSH from Azure's internal services
    destination_address_prefix   = "*"
  }

  tags = {
    tenant = var.tenant_id
  }
}

# Create a new subnet within the tenant's Virtual Network.
# The subnet's address prefix is dynamically generated using a random octet to prevent collisions.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Associate the newly created subnet with the tenant's Network Security Group (NSG).
# This applies the NSG rules to all resources within this subnet.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Standard Static Public IP address for the VM.
# This is required for management agent connectivity in public subnets.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # Standard SKU is recommended for production workloads
  
  tags = {
    tenant = var.tenant_id
  }
}

# Create a Network Interface Card (NIC) for the VM.
# It is configured to use the dynamically created subnet and associated with the public IP.
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
    tenant = var.tenant_id
  }
}

# Deploy the Azure Windows Virtual Machine
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "vmadmin"
  admin_password      = random_password.admin_password.result # Set generated password
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # Critical: Custom image ID from shared image gallery or managed image
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/windows-2019-azure-19395870884"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Enable boot diagnostics to allow access to serial console for troubleshooting
  boot_diagnostics {}

  # Custom data script to be executed on first boot, base64 encoded as required by Azure.
  custom_data = base64encode(local.user_data_script)

  tags = {
    tenant = var.tenant_id
    environment = "private-cloud"
  }
}


# --- Outputs ---

# Output the private IP address of the virtual machine
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID
output "instance_id" {
  description = "The ID of the virtual machine within Azure."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

# Output the randomly generated administrator password (marked as sensitive)
output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}