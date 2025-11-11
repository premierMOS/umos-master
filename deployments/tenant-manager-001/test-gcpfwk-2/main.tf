# Required providers
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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Google Cloud provider configuration
provider "google" {
  project = var.project_id
  region  = var.region
}

# Terraform variables for key configuration values, with default values from JSON.
# This prevents interactive prompts during 'terraform plan' or 'terraform apply'.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwk-2"
}

variable "region" {
  description = "The GCP region where the resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (e.g., e2-micro, n1-standard-1) for the VM."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used in resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux" # From os.type in JSON
}

variable "custom_script" {
  description = "A custom script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n" # From platform.customScript in JSON
}

variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
  default     = "umos-ab24d" # From gcpDefaultProjectId in JSON
}

# --- GCP Tenant Isolation and Networking Setup (Get-or-Create Pattern) ---

# Resource to generate a random second octet for the unique subnet IP range.
resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name # Ensures uniqueness for each instance deployment
  }
}

# Resource to generate a random third octet for the unique subnet IP range.
resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name # Ensures uniqueness for each instance deployment
  }
}

# Null resource to idempotently create the tenant-specific VPC network using gcloud CLI.
# This ensures the VPC exists before dependent resources try to use it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
    # Suppress output, rely on exit code for '||'
  }
}

# Data source to read the details of the tenant VPC network after it's provisioned.
data "google_compute_network" "tenant_vpc" {
  name    = "pmos-tenant-${var.tenant_id}-vpc"
  project = var.project_id
  depends_on = [
    null_resource.vpc_provisioner # Ensure VPC is created before trying to read it
  ]
}

# Null resource to idempotently create a shared firewall rule for internal network traffic.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before creating rules within it
  ]
}

# Null resource to idempotently create a shared firewall rule for IAP SSH access (Linux only).
resource "null_resource" "allow_iap_ssh_provisioner" {
  count = var.os_type == "Linux" ? 1 : 0 # Only provision for Linux VMs
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before creating rules within it
  ]
}

# Create a unique subnetwork for this deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC is ready
  ]
}

# --- SSH Key Pair Generation (for Linux VMs) ---

# Generate a new TLS private key for SSH access.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0 # Only generate for Linux VMs
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Virtual Machine Deployment ---

# Primary compute resource: Google Compute Engine virtual machine.
resource "google_compute_instance" "this_vm" {
  project            = var.project_id
  name               = var.instance_name
  machine_type       = var.vm_size
  zone               = "${var.region}-c" # Using 'c' zone for simplicity, can be randomized if needed.
  deletion_protection = false # As per instruction.

  # Boot disk configuration, using the specified custom image name.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Use the exact cloud image name provided.
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # Assign an ephemeral public IP address for direct connectivity and management agents.
    access_config {
      // Ephemeral public IP is assigned here.
    }
  }

  # Service account with Cloud Platform scopes for instance identity and access.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Conditional metadata for startup script and SSH keys.
  # Using metadata_startup_script for the user-provided script.
  metadata_startup_script = var.custom_script

  # Metadata block for SSH keys (Linux only)
  metadata = var.os_type == "Linux" ? {
    # Format for SSH keys: "user:ssh-rsa AAAAB3NzaC..."
    ssh-keys = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
  } : {} # Empty map if not Linux

  # Conditional tags for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Ensure resources are created in order.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner # Terraform handles `count` implicitly for depends_on
  ]
}

# --- Per-Instance Firewall Rules for Public Access ---

# Firewall rule to allow public SSH access to this specific instance (Linux only).
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists
  ]
}

# Firewall rule to allow public RDP access to this specific instance (Windows only).
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
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

# Firewall rule to allow public WinRM access to this specific instance (Windows only).
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
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


# --- Outputs ---

# Output the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the public IP address of the virtual machine.
output "public_ip" {
  description = "The public IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the network tags associated with the instance.
output "network_tags" {
  description = "Network tags applied to the instance for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key (sensitive).
output "private_ssh_key" {
  description = "The generated private SSH key for accessing Linux VMs."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A (VM is not Linux)"
  sensitive   = true
}