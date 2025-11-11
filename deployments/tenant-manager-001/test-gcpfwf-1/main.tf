# This Terraform configuration deploys a Google Cloud Platform virtual machine
# based on the provided JSON specification. It incorporates advanced features
# like tenant-isolated networking, dynamic IP range allocation, SSH key management,
# and custom startup scripts.

# Required providers for Google Cloud, TLS key generation, and random integer generation.
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
  }
}

# Google Cloud provider configuration.
# The 'project' attribute is intentionally omitted as per critical instructions,
# relying on the environment or gcloud configuration.
provider "google" {
  region = var.region
}

# --- Input Variables ---

# Name of the virtual machine instance.
variable "instance_name" {
  type        = string
  default     = "test-gcpfwf-1"
  description = "Name of the virtual machine instance."
}

# Google Cloud region for deployment.
variable "region" {
  type        = string
  default     = "us-central1"
  description = "Google Cloud region for deployment."
}

# Machine type for the virtual machine (e.g., e2-micro, n1-standard-1).
variable "vm_size" {
  type        = string
  default     = "e2-micro"
  description = "Machine type for the virtual machine."
}

# Unique identifier for the tenant, used in naming shared networking resources.
variable "tenant_id" {
  type        = string
  default     = "tenant-manager-001"
  description = "Unique identifier for the tenant."
}

# Operating system type, used for conditional resource creation (e.g., Linux for SSH, Windows for RDP).
variable "os_type" {
  type        = string
  default     = "Linux" # Derived from os.type in the provided JSON
  description = "Operating system type (Linux or Windows)."
}

# Custom script to be executed on instance startup.
variable "custom_script" {
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to run on instance startup."
}

# The exact cloud image name to be used for the VM.
# This value is provided explicitly in the critical instructions.
variable "image_name" {
  type        = string
  default     = "ubuntu-22-04-19271224598"
  description = "Custom image name for the VM."
}

# --- Data Sources ---

# Fetches the current Google Cloud project ID, necessary for gcloud commands.
data "google_project" "project" {}

# --- SSH Key Pair Generation (for Linux deployments) ---

# Generates an RSA private key locally. This key will be used for SSH access.
# The 'comment' argument is explicitly forbidden as per critical instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- CRITICAL GCP NETWORKING, CONNECTIVITY & TENANT ISOLATION INSTRUCTIONS ---

# Get-or-Create Tenant VPC Network:
# This null_resource executes a gcloud command to ensure a tenant-specific VPC network exists.
# It first attempts to describe the network; if it doesn't exist (indicated by non-zero exit code),
# it proceeds to create it. This makes the operation idempotent.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the provisioned tenant VPC network details.
# 'depends_on' ensures this data source runs only after the network is guaranteed to exist.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = data.google_project.project.project_id
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is provisioned before reading
}

# Get-or-Create Shared Firewall Rule: Allow Internal Traffic.
# Allows all traffic within the 10.0.0.0/8 private IP range, facilitating internal communications.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Depends on VPC existing
}

# Get-or-Create Shared Firewall Rule: Allow IAP SSH.
# Enables SSH access through Google Cloud's Identity-Aware Proxy (IAP) to instances tagged 'ssh-via-iap'.
# The source range 35.235.240.0/20 is the official IAP IP range.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Depends on VPC existing
}

# Generate a random integer between 2 and 254 to ensure a unique third octet
# for the subnet's IP CIDR range, preventing IP overlap in multi-deployment scenarios.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a unique subnetwork for this specific deployment within the shared tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  project       = data.google_project.project.project_id
}

# --- Virtual Machine Deployment ---

# Resource: Google Compute Engine Virtual Machine.
# Named "this_vm" as per critical instructions.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Defaulting to zone 'a' within the specified region
  deletion_protection = false # As per instruction

  # CRITICAL: The 'project' attribute is omitted from this resource block
  # as per critical instructions.

  # Boot disk configuration, using the specified custom image.
  boot_disk {
    initialize_params {
      image = var.image_name
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: The 'access_config' block is intentionally omitted here to prevent
    # the assignment of a public IP address, ensuring connectivity via IAP only.
  }

  # Service account with necessary scopes.
  service_account {
    scopes = ["cloud-platform"]
    # This block MUST NOT contain an access_config.
  }

  # Apply instance tags conditionally based on OS type for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for SSH keys (for Linux instances).
  # The 'ssh-keys' entry allows the generated key to be used for SSH access.
  metadata = var.os_type == "Linux" ? {
    "ssh-keys" = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  } : {}

  # User data/custom script for startup, using the 'metadata_startup_script' argument.
  metadata_startup_script = var.custom_script

  # Explicit dependencies to ensure networking resources are ready before the VM is created.
  depends_on = [
    data.google_compute_network.tenant_vpc,
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner
  ]
}

# --- Per-Instance Firewall Rules for Public Access ---

# Firewall rule to allow public SSH access for Linux instances.
# This rule is conditionally created only if the OS type is "Linux".
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create if OS is Linux

  name        = "pmos-instance-${var.instance_name}-allow-ssh"
  network     = data.google_compute_network.tenant_vpc.self_link
  project     = data.google_project.project.project_id
  description = "Allow public SSH traffic to ${var.instance_name}"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]
}

# Firewall rule to allow public RDP access for Windows instances.
# This rule is conditionally created only if the OS type is "Windows".
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create if OS is Windows

  name        = "pmos-instance-${var.instance_name}-allow-rdp"
  network     = data.google_compute_network.tenant_vpc.self_link
  project     = data.google_project.project.project_id
  description = "Allow public RDP traffic to ${var.instance_name}"

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]
}

# Firewall rule to allow public WinRM access for Windows instances.
# This rule is conditionally created only if the OS type is "Windows".
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create if OS is Windows

  name        = "pmos-instance-${var.instance_name}-allow-winrm"
  network     = data.google_compute_network.tenant_vpc.self_link
  project     = data.google_project.project.project_id
  description = "Allow public WinRM (HTTP/HTTPS) traffic to ${var.instance_name}"

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # HTTP and HTTPS WinRM ports
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
}


# --- Outputs ---

# Output: Private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed VM."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output: Google Cloud's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

# Output: Networking tags applied to the instance.
output "network_tags" {
  description = "Networking tags applied to the VM instance for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

# Output: Generated private SSH key.
# This output is marked as sensitive to prevent its value from being displayed
# in plain text in Terraform logs or state.
output "private_ssh_key" {
  description = "The private key for SSH access to the VM (sensitive)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}