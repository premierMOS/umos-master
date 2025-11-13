# Configure the Azure provider
# This block specifies the Azure provider and its version.
# The 'features' block is required by the AzureRM provider but can be empty.
# 'subscription_id' is dynamically set from a variable.
# 'skip_provider_registration' is explicitly enabled to prevent permissions errors
# in CI/CD environments where the service principal might not have permission to register providers.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true
}

# ---------------------------------------------------------------------------------------------------------------------
# INPUT VARIABLES
# These variables define configurable parameters for the VM deployment.
# Each variable is declared with a default value taken directly from the provided JSON configuration,
# ensuring the script can run without interactive prompts.
# ---------------------------------------------------------------------------------------------------------------------

# The desired name for the virtual machine instance.
variable "instance_name" {
  type        = string
  description = "The name of the virtual machine instance."
  default     = "test-azure"
}

# The Azure region where the virtual machine will be deployed.
variable "region" {
  type        = string
  description = "The Azure region to deploy the VM."
  default     = "East US"
}

# The size/SKU of the virtual machine.
variable "vm_size" {
  type        = string
  description = "The size (SKU) of the virtual machine."
  default     = "Standard_B1s"
}

# The tenant identifier used for naming conventions of shared networking resources.
variable "tenant_id" {
  type        = string
  description = "A unique identifier for the tenant, used in resource naming."
  default     = "tenant-manager-001"
}

# An optional custom script to run on the VM after provisioning.
# This will be passed as user data/custom data to the instance.
variable "custom_script" {
  type        = string
  description = "A custom script to execute on the VM upon startup."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# The name of the existing Azure Resource Group.
# This resource group is assumed to exist and will not be created by this script.
variable "azure_resource_group_name" {
  type        = string
  description = "The name of the existing Azure Resource Group where resources will be deployed."
  default     = "umos"
}

# The Azure subscription ID where the resources will be deployed.
# This is critical for the Azure provider configuration and image lookup.
variable "subscription_id" {
  type        = string
  description = "The Azure Subscription ID."
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

# ---------------------------------------------------------------------------------------------------------------------
# DATA SOURCES
# Data sources are used to retrieve information about existing resources.
# ---------------------------------------------------------------------------------------------------------------------

# Look up the existing Azure Resource Group.
# This data source references the resource group specified in the configuration, which is assumed to already exist.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group_name
}

# Attempt to look up an existing Virtual Network (VNet) for the specific tenant.
# This implements the "get-or-create" pattern for tenant-specific networking.
data "azurerm_virtual_network" "existing_vnet" {
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  # The 'count' meta-argument would typically go here if we were using count on the data source,
  # but for a single lookup it's implicit that if it doesn't exist, id will be null.
  # We use the length(id) check in the 'locals' block and the resource 'count'.
  lifecycle {
    ignore_changes = all # Ignore changes to prevent state refresh issues if the VNet is manually changed.
  }
}

# Attempt to look up an existing Network Security Group (NSG) for the specific tenant.
# This implements the "get-or-create" pattern for tenant-specific networking.
data "azurerm_network_security_group" "existing_nsg" {
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
  lifecycle {
    ignore_changes = all # Ignore changes to prevent state refresh issues if the NSG is manually changed.
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# LOCAL VALUES
# Local values are used to derive values from input variables or data sources, making the configuration more readable.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # Dynamically select the VNet ID:
  # If an existing VNet is found, use its ID; otherwise, use the ID of the newly created VNet.
  vnet_id = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.id : azurerm_virtual_network.tenant_vnet[0].id
  # Dynamically select the VNet Name:
  # If an existing VNet is found, use its name; otherwise, use the name of the newly created VNet.
  vnet_name = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? data.azurerm_virtual_network.existing_vnet.name : azurerm_virtual_network.tenant_vnet[0].name
  # Dynamically select the NSG ID:
  # If an existing NSG is found, use its ID; otherwise, use the ID of the newly created NSG.
  nsg_id = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? data.azurerm_network_security_group.existing_nsg.id : azurerm_network_security_group.tenant_nsg[0].id
}


# ---------------------------------------------------------------------------------------------------------------------
# TLS PRIVATE KEY
# Generates an SSH key pair to be used for administrative access to the VM.
# ---------------------------------------------------------------------------------------------------------------------

# Generate a new RSA private key for SSH access.
# This key pair will be used for logging into the Linux virtual machine.
# The 'comment' argument is explicitly forbidden by instructions, so it's omitted.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# ---------------------------------------------------------------------------------------------------------------------
# AZURE NETWORKING RESOURCES (TENANT ISOLATION)
# These resources implement the "get-or-create" pattern for VNet and NSG to ensure tenant isolation.
# ---------------------------------------------------------------------------------------------------------------------

# Conditionally create an Azure Virtual Network (VNet) for the tenant.
# The VNet is only created if a VNet with the specified tenant name does not already exist.
resource "azurerm_virtual_network" "tenant_vnet" {
  # Create the VNet only if the data source for 'existing_vnet' did not find an ID (i.e., its length is 0).
  count = length(data.azurerm_virtual_network.existing_vnet.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    tenant_id = var.tenant_id
  }
}

# Create a new subnet specifically for this virtual machine deployment.
# This ensures that each deployment gets its own dedicated subnet within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name # Referencing the tenant VNet (either existing or newly created)
  address_prefixes     = ["10.0.1.0/24"]

  depends_on = [
    azurerm_virtual_network.tenant_vnet # Ensure VNet is available before creating subnet
  ]
}

# Conditionally create an Azure Network Security Group (NSG) for the tenant.
# The NSG is only created if an NSG with the specified tenant name does not already exist.
resource "azurerm_network_security_group" "tenant_nsg" {
  # Create the NSG only if the data source for 'existing_nsg' did not find an ID.
  count = length(data.azurerm_network_security_group.existing_nsg.id) > 0 ? 0 : 1

  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH from Azure's infrastructure.
  # This is crucial for management agents and specific Azure services to interact with the VM.
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
    tenant_id = var.tenant_id
  }
}

# Associate the newly created subnet with the tenant's Network Security Group.
# This applies the defined security rules to the traffic flowing into and out of the subnet.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id # Referencing the tenant NSG (either existing or newly created)
}

# ---------------------------------------------------------------------------------------------------------------------
# AZURE VM NETWORKING
# These resources define the public IP and network interface for the virtual machine.
# ---------------------------------------------------------------------------------------------------------------------

# Create an Azure Public IP address for the virtual machine.
# This ensures the VM has external connectivity, which is necessary for management agents
# and for the custom script if it needs to download resources from the internet.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Dynamic" # Dynamic allocation means the IP might change after VM restart
  sku                 = "Basic"   # Basic SKU is typical for dynamic public IPs
}

# Create an Azure Network Interface for the virtual machine.
# This interface connects the VM to the subnet and associates it with the public IP address.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id           # Associate with the dedicated subnet
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id           # Associate with the public IP
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# VIRTUAL MACHINE
# The primary resource for deploying the virtual machine instance.
# ---------------------------------------------------------------------------------------------------------------------

# Deploy an Azure Linux Virtual Machine.
# This is the main compute resource for the deployment.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  location                        = data.azurerm_resource_group.rg.location
  resource_group_name             = data.azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = "packer" # Standard admin username for hardened images
  network_interface_ids           = [azurerm_network_interface.this_nic.id]
  disable_password_authentication = true # Enforce SSH key-based authentication

  # Admin SSH key configuration, using the generated public key.
  admin_ssh_key {
    username  = "packer"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # OS Disk configuration.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # Standard Local Redundant Storage
  }

  # Source image configuration.
  # This uses a specific custom image ID as per the critical instructions.
  # The image ID is constructed using the subscription, resource group, and the provided image name.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19340995664"

  # Custom data (user data) to execute a script on VM startup.
  # The script is base64 encoded as required by Azure.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access.
  # This helps in troubleshooting VM boot issues.
  boot_diagnostics {}

  tags = {
    environment = "dev"
    tenant_id   = var.tenant_id
    instance    = var.instance_name
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# OUTPUTS
# These outputs expose key information about the deployed virtual machine.
# ---------------------------------------------------------------------------------------------------------------------

# Expose the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Expose the cloud provider's native instance ID of the virtual machine.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Expose the generated private SSH key.
# This output is marked as sensitive to prevent its value from being displayed in plaintext in logs.
output "private_ssh_key" {
  description = "The private SSH key generated for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}