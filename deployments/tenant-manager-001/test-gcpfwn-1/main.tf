# Terraform HCL script to deploy a virtual machine on Google Cloud Platform

# Configure the required providers
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Google Cloud Platform provider configuration
# Uses the project_id variable for global project context
provider "google" {
  project = var.project_id
  region  = var.region
}

# Declare Terraform variables for key configuration values,
# with default values populated directly from the JSON config.

# Instance name
variable "instance_name" {
  type        = string
  description = "Name for the virtual machine instance."
  default     = "test-gcpfwn-1"
}

# GCP region for deployment
variable "region" {
  type        = string
  description = "The GCP region to deploy resources in."
  default     = "us-central1"
}

# Virtual machine size (machine type)
variable "vm_size" {
  type        = string
  description = "The machine type for the virtual machine."
  default     = "e2-micro"
}

# Tenant ID for resource naming and isolation
variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant."
  default     = "tenant-manager-001"
}

# Operating System type (Linux or Windows)
variable "os_type" {
  type        = string
  description = "The operating system type of the VM (e.g., Linux, Windows)."
  default     = "Linux"
}

# Custom script to be executed on instance startup (user data)
variable "custom_script" {
  type        = string
  description = "User data script to run on instance startup."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Google Cloud Project ID
variable "project_id" {
  type        = string
  description = "The Google Cloud Project ID to deploy resources into."
  default     = "umos-ab24d"
}

# Generate a TLS private key for SSH access if the OS type is Linux.
# This key will be used to create the SSH key pair metadata.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# CRITICAL GCP NETWORKING: Get-or-Create Tenant VPC Network
# This null_resource uses gcloud CLI to check if the tenant-specific VPC network exists.
# If it doesn't exist, it creates it. This ensures idempotency for shared tenant resources.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant VPC network after it's guaranteed to exist.
data "google_compute_network" "tenant_vpc" {
  name    = "pmos-tenant-${var.tenant_id}-vpc"
  project = var.project_id
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

# CRITICAL GCP NETWORKING: Get-or-Create Shared Firewall Rule for Internal Traffic
# Allows all traffic within the 10.0.0.0/8 range, common for internal communications.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# CRITICAL GCP NETWORKING: Get-or-Create Shared Firewall Rule for IAP SSH
# Allows SSH access via Google Cloud IAP, targeting instances with the 'ssh-via-iap' tag.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# Random integer to generate a unique second octet for the subnet IP range
resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Random integer to generate a unique third octet for the subnet IP range
resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# CRITICAL GCP NETWORKING: Create a new unique subnet for this deployment
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  project       = var.project_id
  depends_on = [
    random_integer.subnet_octet_2,
    random_integer.subnet_octet_3,
    data.google_compute_network.tenant_vpc
  ]
}

# CRITICAL GCP NETWORKING: Create per-instance firewall rule for public SSH access (Linux only)
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]

  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# CRITICAL GCP NETWORKING: Create per-instance firewall rule for public RDP access (Windows only)
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]

  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# CRITICAL GCP NETWORKING: Create per-instance firewall rule for public WinRM access (Windows only)
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]

  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# Deploy the virtual machine instance
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Using zone 'a' for simplicity, could be variable
  project      = var.project_id

  # CRITICAL IMAGE NAME: Use the specified custom image name
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598"
    }
  }

  # CRITICAL NETWORKING: Deploy into the unique subnet and assign an ephemeral public IP
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      # Ephemeral public IP is assigned here, required for direct SSH/RDP connectivity.
    }
  }

  # Service account configuration with appropriate scopes
  service_account {
    scopes = ["cloud-platform"]
  }

  # Tags for instance-specific firewall rules and IAP access
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # CRITICAL METADATA STRUCTURE: All metadata in a single map
  metadata = {
    # Custom startup script if provided
    startup-script = var.custom_script
    # SSH keys for Linux instances
    ssh-keys       = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # Protection against accidental deletion
  deletion_protection = false

  # CRITICAL DEPENDENCY INSTRUCTION: Explicitly depend on conditionally created resources.
  # Terraform handles resources with count=0 gracefully in depends_on.
  depends_on = [
    tls_private_key.admin_ssh,
    google_compute_subnetwork.this_subnet,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm,
    null_resource.allow_internal_provisioner, # Ensure shared internal firewall is in place
    null_resource.allow_iap_ssh_provisioner # Ensure shared IAP firewall is in place
  ]
}

# Output the private IP address of the virtual machine
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the public IP address of the virtual machine
output "public_ip" {
  description = "The public IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

# Output the cloud provider's native instance ID
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the network tags applied to the instance
output "network_tags" {
  description = "Network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key (sensitive)
output "private_ssh_key" {
  description = "The generated private SSH key for Linux instances."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux VM"
  sensitive   = true
}