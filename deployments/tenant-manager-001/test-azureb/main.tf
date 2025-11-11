# Terraform block specifies required providers and their versions
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
  }
}

# Configure the Microsoft Azure Provider
# CRITICAL: `skip_provider_registration` and `features {}` are required for this environment.
provider "azurerm" {
  subscription_id        = var.subscription_id
  skip_provider_registration = true # CRITICAL: Disable automatic resource provider registration
  features {} # CRITICAL: Required for this environment to prevent permissions errors
}

#region Variables
# CRITICAL: All variables MUST include a 'default' value set directly from the provided configuration.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azureb"
}

variable "region" {
  description = "The Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming to ensure isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to run on the VM at startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group where resources will be deployed."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID to deploy resources into."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}
#endregion

#region Data Sources for Existing Resources
# CRITICAL: Use a data source for the Azure Resource Group as it is assumed to already exist.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION: Data source to query for an existing VNet for tenant isolation.
# This data source does not fail when no resources are found.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION: Data source to query for an existing Network Security Group for tenant isolation.
# This data source does not fail when no resources are found.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}
#endregion

#region Locals
# CRITICAL AZURE NETWORKING & TENANT ISOLATION: Local variables to select the VNet ID and name based on whether it was found or created.
locals {
  vnet_id = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? data.azurerm_resources.existing_nsg_query.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}
#endregion

#region SSH Key Generation
# CRITICAL FOR LINUX DEPLOYMENTS: Generate an SSH key pair for secure access to the VM.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'comment' argument is FORBIDDEN in this resource block.
}
#endregion

#region Azure Network Resources
# CRITICAL AZURE NETWORKING & TENANT ISOLATION: Conditionally create the Virtual Network if the query finds no existing VNet.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space for the VNet

  tags = {
    tenant_id = var.tenant_id
  }
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION: Conditionally create the Network Security Group if the query finds no existing NSG.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # CRITICAL AZURE NETWORKING & TENANT ISOLATION: Security rule to allow SSH for Linux VMs.
  security_rule {
    name                       = "AllowSSH" # For Linux, port 22
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22" # SSH port
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  tags = {
    tenant_id = var.tenant_id
  }
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION: Create a NEW subnet for THIS deployment.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.1.0/24"] # Example subnet prefix, assuming VNet 10.0.0.0/16

  tags = {
    instance_name = var.instance_name
    tenant_id     = var.tenant_id
  }
}

# CRITICAL AZURE NETWORKING & TENANT ISOLATION: Associate the newly created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# CRITICAL NETWORKING REQUIREMENT: Create a Public IP for the VM to ensure connectivity for management agents like AWS SSM.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Dynamic" # Dynamic allocation for cost efficiency; Static for predictable IP

  tags = {
    instance_name = var.instance_name
    tenant_id     = var.tenant_id
  }
}

# Create a Network Interface for the Virtual Machine.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id # CRITICAL AZURE NETWORKING
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id # CRITICAL NETWORKING REQUIREMENT
  }

  tags = {
    instance_name = var.instance_name
    tenant_id     = var.tenant_id
  }
}
#endregion

#region Virtual Machine Resource
# Deploy the Virtual Machine.
# CRITICAL: Name the primary compute resource "this_vm".
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                = var.instance_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = "azureuser" # Standard admin user for Linux VMs

  # CRITICAL FOR LINUX DEPLOYMENTS: Attach the generated SSH public key for secure authentication.
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Use the exact custom image name provided.
  # This image ID includes the subscription and resource group context.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size for the OS disk
  }

  # CRITICAL: Attach the network interface to the VM.
  network_interface_ids = [azurerm_network_interface.this_nic.id]

  # USER DATA/CUSTOM SCRIPT: Pass the custom script as custom_data, base64 encoded.
  custom_data = base64encode(var.custom_script)

  # CRITICAL AZURE VM ARGUMENT: Enable serial console for Linux VMs for debugging.
  boot_diagnostics {}

  # CRITICAL AZURE VM ARGUMENT INSTRUCTION: The 'azurerm_linux_virtual_machine' resource DOES NOT support a top-level 'enabled' argument.

  tags = {
    instance_name = var.instance_name
    tenant_id     = var.tenant_id
    os_type       = "Linux"
  }
}
#endregion

#region Outputs
# CRITICAL: Output block named "private_ip" exposes the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# CRITICAL: Output block named "instance_id" exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine within the cloud provider."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# CRITICAL FOR LINUX DEPLOYMENTS: Output block named "private_ssh_key" exposes the generated private key.
# This output MUST be marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}
#endregion