# Configure the Azure Provider
# This block specifies the AzureRM provider and authenticates it.
# The `skip_provider_registration` argument is used to prevent the provider from attempting
# to register resource providers, which is often not permitted by CI/CD service principals.
# The `subscription_id` is passed via a variable for flexibility.
provider "azurerm" {
  features {}
  subscription_id        = var.subscription_id
  skip_provider_registration = true # Required for CI/CD environment permissions
}

# --- Input Variables ---
# Terraform variables are declared here to make the script configurable.
# Each variable includes a 'default' value taken directly from the provided JSON configuration,
# preventing interactive prompts during execution.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azurea"
}

variable "region" {
  description = "The Azure region where resources will be deployed."
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "The size of the virtual machine (e.g., Standard_B1s)."
  type        = string
  default     = "Standard_B1s"
}

variable "tenant_id" {
  description = "The ID of the tenant for resource naming and isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "azure_resource_group" {
  description = "The name of the pre-existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID where resources will be deployed."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "custom_script" {
  description = "A custom script to execute on the VM at startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Data Sources ---
# Data sources are used to fetch information about existing Azure resources.

# Data source for the existing Azure Resource Group.
# This avoids creating a new resource group and ensures resources are deployed
# into the specified, pre-existing group.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Data source to check if a tenant-specific Virtual Network (VNet) already exists.
# This supports the "get-or-create" pattern for tenant isolation.
data "azurerm_virtual_network" "existing_vnet" {
  count               = try(azurerm_virtual_network.tenant_vnet[0].id, null) == null ? 1 : 0 # Only lookup if tenant_vnet is not created
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Data source to check if a tenant-specific Network Security Group (NSG) already exists.
# This supports the "get-or-create" pattern for tenant isolation.
data "azurerm_network_security_group" "existing_nsg" {
  count               = try(azurerm_network_security_group.tenant_nsg[0].id, null) == null ? 1 : 0 # Only lookup if tenant_nsg is not created
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# --- Locals Block ---
# Locals are used to define reusable expressions, particularly for the "get-or-create" logic.

locals {
  # Dynamically select the VNet ID:
  # If the existing_vnet data source found a VNet (count > 0, so index 0 exists), use its ID.
  # Otherwise, use the ID of the newly created tenant_vnet resource.
  vnet_id = length(data.azurerm_virtual_network.existing_vnet) > 0 ? data.azurerm_virtual_network.existing_vnet[0].id : azurerm_virtual_network.tenant_vnet[0].id
  # Dynamically select the VNet Name:
  # Same logic as vnet_id, but for the VNet name.
  vnet_name = length(data.azurerm_virtual_network.existing_vnet) > 0 ? data.azurerm_virtual_network.existing_vnet[0].name : azurerm_virtual_network.tenant_vnet[0].name

  # Dynamically select the NSG ID:
  # If the existing_nsg data source found an NSG, use its ID.
  # Otherwise, use the ID of the newly created tenant_nsg resource.
  nsg_id = length(data.azurerm_network_security_group.existing_nsg) > 0 ? data.azurerm_network_security_group.existing_nsg[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# --- Resource Blocks ---

# Generate an SSH private key for secure authentication to the Linux VM.
# The 'tls_private_key' resource is used to create a new RSA key pair.
# The comment argument is explicitly forbidden as per instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Networking for Tenant Isolation (Get-or-Create VNet and NSG) ---

# Conditionally create a Virtual Network (VNet) for the tenant.
# The 'count' meta-argument ensures the VNet is created only if it wasn't found by the data source.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_virtual_network.existing_vnet) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Example address space
}

# Create a dedicated subnet for this VM within the tenant's VNet.
# This ensures further network segmentation per deployment.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.1.0/24"] # Example unique address prefix
}

# Conditionally create a Network Security Group (NSG) for the tenant.
# The 'count' meta-argument ensures the NSG is created only if it wasn't found by the data source.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_network_security_group.existing_nsg) > 0 ? 0 : 1
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  # Security rule to allow SSH access specifically from Azure's infrastructure.
  # This is crucial for management agents and basic connectivity testing.
  security_rule {
    name                       = "AllowSSH_from_AzureCloud"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "AzureCloud" # Allows SSH from Azure's backend services
    destination_address_prefix = "*"
  }
}

# Associate the newly created subnet with the tenant's NSG.
# This applies the NSG rules to all resources within this subnet.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Public IP Address for the virtual machine.
# This ensures the VM has a public facing IP for outbound connectivity,
# critical for management tools like SSM agent, even if inbound access is restricted by NSG.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Basic"
}

# Create a Network Interface for the virtual machine.
# This interface connects the VM to the subnet and associates the public IP and NSG.
resource "azurerm_network_interface" "this_nic" {
  name                = "${var.instance_name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  network_security_group_id = local.nsg_id # Associate the tenant NSG

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet.id        # Connect to the dedicated subnet
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this_pip.id # Assign the public IP
  }
}

# Deploy the Azure Linux Virtual Machine.
# This is the primary compute resource, named "this_vm" as per instructions.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  size                            = var.vm_size
  admin_username                  = "packer" # Common username for custom images
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this_nic.id]

  # Configuration for the OS disk attached to the VM.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30 # Default disk size
  }

  # Reference to the custom image ID.
  # The exact format is crucial for custom image deployments on Azure.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19340995664"

  # SSH key configuration for the admin user.
  # Uses the public key generated by the 'tls_private_key' resource.
  admin_ssh_key {
    username  = "packer"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  # Pass custom script as user data (custom_data) to the VM.
  # The script is base64 encoded as required by Azure.
  custom_data = base64encode(var.custom_script)

  # Enable boot diagnostics for serial console access, useful for debugging.
  boot_diagnostics {}
}

# --- Outputs ---
# Output blocks expose important information about the deployed resources.

# Expose the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Expose the cloud provider's native instance ID of the virtual machine.
output "instance_id" {
  description = "The unique ID of the virtual machine in Azure."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Expose the generated private SSH key.
# This output is marked as sensitive to prevent its value from being displayed in plaintext
# in Terraform logs, which is a critical security practice.
output "private_ssh_key" {
  description = "The private SSH key generated for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}