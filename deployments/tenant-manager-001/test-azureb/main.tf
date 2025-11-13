# Configure the Azure Provider
# This provider block configures Terraform to manage resources in Azure.
# The subscription ID is pulled from a variable to ensure consistent deployment
# across environments. 'skip_provider_registration' is set to true as per
# environment requirements to prevent permission errors.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# Configure the TLS Provider
# This provider is used to generate a local SSH key pair for secure access
# to Linux virtual machines.
provider "tls" {
  # No special configuration needed for TLS provider
}

# --- Input Variables ---
# All key configuration values are declared as variables with default values
# directly from the provided JSON configuration. This prevents interactive
# prompts and ensures the script is ready to use out-of-the-box.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azureb"
}

variable "region" {
  description = "The Azure region where the resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size/SKU of the virtual machine."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used in naming conventions for tenant-isolated resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to be executed on the VM after provisioning (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group where resources will be deployed."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "os_image_name" {
  description = "The exact name of the custom OS image to use for the virtual machine."
  type        = string
  default     = "ubuntu-22-04-19340995664"
}

# --- Data Sources ---

# Data source for the existing Azure Resource Group.
# The resource group is assumed to exist and is looked up using its name.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Data source to check for an existing Virtual Network (VNet) for the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  # CRITICAL ANTI-CYCLE: FORBIDDEN from referencing 'local' variables here.
  # Arguments constructed directly from variables or other data sources.
}

# Data source to check for an existing Network Security Group (NSG) for the tenant.
# This is part of the "get-or-create" pattern for tenant isolation.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
  # CRITICAL ANTI-CYCLE: FORBIDDEN from referencing 'local' variables here.
  # Arguments constructed directly from variables or other data sources.
}

# --- Locals Block ---
# A locals block is used to conditionally select IDs/names based on whether
# existing resources were found or new ones were created, ensuring a seamless
# "get-or-create" pattern.

locals {
  # Selects the VNet ID: either from the existing data source or the newly created resource.
  vnet_id = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id

  # Selects the VNet name: either from the existing data source or the newly created resource.
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name

  # Selects the NSG ID: either from the existing data source or the newly created resource.
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}

# --- Resources ---

# Resource for generating an SSH private key locally.
# This key is used to authenticate with the Linux virtual machine.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: 'comment' argument is FORBIDDEN for tls_private_key.
}

# Conditional creation of a Virtual Network (VNet) for tenant isolation.
# This resource is created only if an existing VNet for the tenant is not found.
resource "azurerm_virtual_network" "tenant_vnet" {
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"] # Example address space
}

# Conditional creation of a Network Security Group (NSG) for tenant isolation.
# This resource is created only if an existing NSG for the tenant is not found.
resource "azurerm_network_security_group" "tenant_nsg" {
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH access from Azure's infrastructure.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "AzureCloud" # Specific Azure service tag
    destination_address_prefix = "*"
  }
}

# Create a dedicated subnet for this virtual machine within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.1.0/24"] # Unique subnet for this VM
}

# Associate the newly created subnet with the tenant's Network Security Group (NSG).
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create an Azure Public IP address for the virtual machine.
# This ensures connectivity for management agents, even with restrictive NSG rules.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard" # Use Standard SKU for public IPs
}

# Create an Azure Network Interface for the virtual machine.
# It's attached to the dedicated subnet and associated with the public IP and NSG.
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

  network_security_group_id = local.nsg_id
}

# Deploy the Azure Linux Virtual Machine.
# This is the primary compute resource, named "this_vm" as per instructions.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  size                            = var.vm_size
  admin_username                  = "azureuser" # Standard admin username for Azure Linux VMs

  # Attach the generated SSH public key for administrator access.
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # Configure the OS disk for the virtual machine.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Define the source image for the VM.
  # CRITICAL: Uses the exact, full custom image ID as specified.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/${var.os_image_name}"

  # Attach the network interface to the VM.
  network_interface_ids = [
    azurerm_network_interface.this_nic.id,
  ]

  # Pass custom data (user data) to the VM for post-provisioning scripts.
  # The script is base64 encoded for Azure.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access.
  boot_diagnostics {}

  # CRITICAL: FORBIDDEN from adding 'enabled' argument directly within this resource block.
}


# --- Outputs ---

# Output the private IP address of the created virtual machine.
# This is useful for internal network access or management.
output "private_ip" {
  description = "The private IP address of the VM."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID of the virtual machine.
# This ID is unique and can be used for direct API calls or cloud console lookups.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated SSH private key.
# CRITICAL: This output is marked as sensitive to prevent its value from being
# displayed in plaintext in Terraform logs. It should be stored securely.
output "private_ssh_key" {
  description = "The generated SSH private key (sensitive)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}