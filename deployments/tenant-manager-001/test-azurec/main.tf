# Configure the AzureRM Provider
# This block configures the Azure provider, specifying the subscription to deploy resources into.
# skip_provider_registration = true is set to prevent permissions errors in CI/CD environments.
# The empty 'features' block is required by the provider.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  skip_provider_registration = true # CRITICAL: Required for this environment to prevent permissions errors.
}

# Declare Terraform variables for key configuration values.
# Each variable includes a 'default' value directly from the provided JSON,
# preventing interactive prompts during Terraform execution.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azurec"
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
  description = "A unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A base64-encoded custom script to be executed on the VM during provisioning."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "azure_resource_group" {
  description = "The name of the existing Azure Resource Group."
  type        = string
  default     = "umos"
}

variable "subscription_id" {
  description = "The Azure Subscription ID."
  type        = string
  default     = "c0ddf8f4-14b2-432e-b2fc-dd8456adda33"
}

variable "os_type" {
  description = "The operating system type (e.g., Linux, Windows) for network security rules."
  type        = string
  default     = "Linux"
}

# Look up the existing Azure Resource Group.
# This data source references an already existing resource group.
data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}

# Generate an SSH key pair for Linux deployments.
# The private key will be used for secure access, and the public key for VM provisioning.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Query for an existing Virtual Network (VNet) for tenant isolation.
# This data source attempts to find a VNet named "pmos-tenant-{tenant_id}-vnet".
# It does not fail if no matching VNet is found.
data "azurerm_resources" "existing_vnet_query" {
  type                = "Microsoft.Network/virtualNetworks"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-vnet"
}

# Conditionally create the Virtual Network (VNet) if it doesn't already exist.
# The 'count' meta-argument ensures creation only when the data query returns no existing VNets.
resource "azurerm_virtual_network" "tenant_vnet" {
  count               = length(data.azurerm_resources.existing_vnet_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    tenant_id = var.tenant_id
  }
}

# Local variables to select the VNet ID and name, whether it was existing or newly created.
locals {
  vnet_id   = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].id : azurerm_virtual_network.tenant_vnet[0].id
  vnet_name = length(data.azurerm_resources.existing_vnet_query.resources) > 0 ? data.azurerm_resources.existing_vnet_query.resources[0].name : azurerm_virtual_network.tenant_vnet[0].name
}

# Create a dedicated subnet for this deployment within the tenant's VNet.
resource "azurerm_subnet" "this_subnet" {
  name                 = "${var.instance_name}-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = local.vnet_name
  address_prefixes     = ["10.0.1.0/24"]

  # CRITICAL: The 'azurerm_subnet' resource does NOT support a 'tags' argument.
  # FORBIDDEN from adding a 'tags' block here.
}

# Query for an existing Network Security Group (NSG) for tenant isolation.
# This data source attempts to find an NSG named "pmos-tenant-{tenant_id}-nsg".
# It does not fail if no matching NSG is found.
data "azurerm_resources" "existing_nsg_query" {
  type                = "Microsoft.Network/networkSecurityGroups"
  resource_group_name = data.azurerm_resource_group.rg.name
  name                = "pmos-tenant-${var.tenant_id}-nsg"
}

# Conditionally create the Network Security Group (NSG) if it doesn't already exist.
# Includes a security rule to allow SSH (port 22) or RDP (port 3389) based on OS type.
resource "azurerm_network_security_group" "tenant_nsg" {
  count               = length(data.azurerm_resources.existing_nsg_query.resources) == 0 ? 1 : 0
  name                = "pmos-tenant-${var.tenant_id}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                       = var.os_type == "Linux" ? "AllowSSH" : "AllowRDP"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = var.os_type == "Linux" ? "22" : "3389"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  tags = {
    tenant_id = var.tenant_id
  }
}

# Local variable to select the NSG ID, whether it was existing or newly created.
locals {
  nsg_id = length(data.azurerm_resources.existing_nsg_query.resources) > 0 ? data.azurerm_resources.existing_nsg_query.resources[0].id : azurerm_network_security_group.tenant_nsg[0].id
}

# Associate the newly created subnet with the tenant's Network Security Group.
resource "azurerm_subnet_network_security_group_association" "this_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.this_subnet.id
  network_security_group_id = local.nsg_id
}

# Create a Public IP address for the VM.
# This is required for agent connectivity (e.g., AWS SSM equivalent) in a public subnet.
resource "azurerm_public_ip" "this_pip" {
  name                = "${var.instance_name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Basic" # Basic SKU is sufficient for general purposes
}

# Create a Network Interface for the Virtual Machine.
# This interface will connect the VM to the subnet and assign a public IP.
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
    instance_name = var.instance_name
    tenant_id     = var.tenant_id
  }
}

# Deploy the Azure Linux Virtual Machine.
# The primary compute resource is named "this_vm" as per instructions.
resource "azurerm_linux_virtual_machine" "this_vm" {
  name                            = var.instance_name
  location                        = data.azurerm_resource_group.rg.location
  resource_group_name             = data.azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  network_interface_ids           = [azurerm_network_interface.this_nic.id]
  disable_password_authentication = true # Enforce SSH key authentication for security

  admin_ssh_key {
    username  = "azureuser"
    public_key = tls_private_key.admin_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # CRITICAL IMAGE NAME INSTRUCTION: Use the specified custom image ID.
  source_image_id = "/subscriptions/${var.subscription_id}/resourceGroups/${data.azurerm_resource_group.rg.name}/providers/Microsoft.Compute/images/ubuntu-22-04-19252758120"

  # User Data/Custom Script: Pass the custom_script to the VM if provided.
  # The script must be base64 encoded for Azure.
  custom_data = base64encode(var.custom_script)

  # CRITICAL: Enable serial console for Linux VMs.
  boot_diagnostics {}

  # CRITICAL: The 'azurerm_linux_virtual_machine' resource does NOT support a top-level 'enabled' argument.
  # FORBIDDEN from adding 'enabled = false' or any 'enabled' argument here.

  tags = {
    instance_name = var.instance_name
    tenant_id     = var.tenant_id
  }
}

# Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = azurerm_network_interface.this_nic.private_ip_address
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The Azure ID of the virtual machine."
  value       = azurerm_linux_virtual_machine.this_vm.id
}

# Output the generated private SSH key.
# This output is marked as sensitive to prevent its value from being displayed in plaintext in the console.
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}