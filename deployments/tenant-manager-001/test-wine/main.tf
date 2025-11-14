# This Terraform configuration deploys a Windows Virtual Machine on Azure.
# It adheres to secure private cloud infrastructure principles, including
# tenant isolation, dynamic networking, and conditional resource creation.

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

  required_version = ">= 1.0.0"
}

# Configure the AzureRM Provider
# Disabling provider registration is crucial for CI/CD environments where the
# service principal might lack permissions to register new resource providers.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

#region Variables
# All key configuration values are declared as variables with default values
# pulled directly from the provided JSON, preventing interactive prompts.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-wine"
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
  description = "A unique identifier for the tenant, used for resource naming and isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to be passed as user data to the VM."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "os_image_name" {
  description = "The name of the custom OS image to use for the VM."
  type        = string
  default     = "windows-2019-19363652771"
}
#endregion

#region Resource Group Lookup
# The Azure Resource Group is assumed to exist. This data source looks up its
# properties, which are then used by other resources for consistency.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}
#endregion

#region Tenant Network Setup (Get-or-Create VNet & NSG)
# This section implements a "get-or-create" pattern for the tenant's Virtual
# Network and Network Security Group, ensuring isolation and preventing conflicts.

# Data source to check for an existing Virtual Network for the tenant.
# CRITICAL ANTI-CYCLE: Direct references to variables/data sources only.
# This prevents circular dependencies with local variables.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the tenant's Virtual Network if it doesn't already exist.
resource "azurerm_virtual_network" "tenant_vnet" {
  # Create only if the data source lookup for existing_vnet found nothing
  count               = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    Environment = "TenantIsolated"
    Tenant      = var.tenant_id
  }
}

# Data source to check for an existing Network Security Group for the tenant.
# CRITICAL ANTI-CYCLE: Direct references to variables/data sources only.
# This prevents circular dependencies with local variables.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Conditionally create the tenant's Network Security Group if it doesn't exist.
resource "azurerm_network_security_group" "tenant_nsg" {
  # Create only if the data source lookup for existing_nsg found nothing
  count               = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH traffic from Azure's infrastructure for management.
  # This rule ensures basic connectivity for management agents like SSM.
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
    Environment = "TenantIsolated"
    Tenant      = var.tenant_id
  }
}

# Locals block to dynamically select the VNet and NSG attributes.
# This ensures that whether the resources were created or looked up, their IDs
# are correctly referenced by subsequent resources.
locals {
  vnet_id   = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id    = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}
#endregion

#region Dynamic Subnet Creation
# Create a unique subnet for this deployment to prevent address space collisions
# within the tenant's VNet. A random octet ensures uniqueness.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254 # Max 254 to keep within common private IP ranges and avoid .0 and .255 for network/broadcast
}

# Create a subnet within the selected VNet. Its name and address prefix are
# dynamically generated to ensure uniqueness per deployment.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet-${random_integer.subnet_octet.result}"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  # Dynamically assign a /24 subnet within the 10.0.0.0/16 space.
  address_prefixes     = ["10.0.${random_integer.subnet_octet.result}.0/24"]
}

# Associate the dynamically created subnet with the tenant's Network Security Group.
# CRITICAL: This method (azurerm_subnet_network_security_group_association) is mandatory
# for NSG association, not via the network interface resource.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}
#endregion

#region Network Interface and Public IP
# Create a Public IP address for the VM to allow outbound connectivity for management agents.
# Uses Standard SKU and Static allocation as required to avoid deployment limitations.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # Required for robust deployments
  domain_name_label   = lower("${var.instance_name}-${random_integer.subnet_octet.result}") # Unique DNS label for public access
}

# Create the Network Interface for the VM.
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
    InstanceName = var.instance_name
  }
}
#endregion

#region Windows Administrator Password
# Generates a strong, random password for the Windows Administrator account.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&" # Custom set of special characters
}
#endregion

#region Virtual Machine Deployment
# Deploy the Azure Windows Virtual Machine.
resource "azurerm_windows_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser" # Standard admin username for Azure Windows VMs
  admin_password      = random_password.admin_password.result # Use the generated strong password
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # OS Disk Configuration
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # Standard Locally Redundant Storage
    name                 = "${var.instance_name}-osdisk"
  }

  # Custom Image Configuration: Using the specific custom image name provided.
  # The source_image_id must be the full ARM ID of the custom image.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  # Custom data (user data) for post-deployment configuration.
  # The script is base64 encoded as required by Azure for custom data.
  custom_data = base64encode(var.custom_script)

  # Enable Boot Diagnostics for serial console access.
  boot_diagnostics {}

  tags = {
    Environment = "Production"
    Purpose     = "PrivateCloudVM"
    Tenant      = var.tenant_id
  }
}
#endregion

#region Outputs
# Outputs provide critical information about the deployed resources.

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

output "instance_id" {
  description = "The unique ID of the virtual machine within Azure."
  value       = azurerm_windows_virtual_machine.this_vm.id
}

output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true # Mark as sensitive to prevent plain-text logging
}
#endregion