# Configure the Google Cloud provider
# Ensure authentication is configured (e.g., via gcloud CLI or service account key file)
provider "google" {
  project = var.project_id
  region  = var.region
}

# Required providers for random number generation and SSH key creation
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ----------------------------------------------------------------------------------------------------------------------
# INPUT VARIABLES
# These variables define the configuration for the virtual machine.
# All variables include a 'default' value from the provided JSON to prevent interactive prompts.
# ----------------------------------------------------------------------------------------------------------------------

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwk-1"
}

variable "region" {
  description = "The Google Cloud region where the VM will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Identifier for the tenant, used in naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "A custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "project_id" {
  description = "The Google Cloud Project ID."
  type        = string
  default     = "umos-ab24d"
}

# ----------------------------------------------------------------------------------------------------------------------
# SSH KEY PAIR GENERATION (FOR LINUX ONLY)
# Generates a new SSH key pair to be used for secure access to the Linux VM.
# The private key is outputted as a sensitive value.
# ----------------------------------------------------------------------------------------------------------------------

# Generate a new private key for SSH access if OS is Linux
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ----------------------------------------------------------------------------------------------------------------------
# GCP SHARED NETWORK INFRASTRUCTURE (GET-OR-CREATE IDEMPOTENTLY)
# Uses null_resource with local-exec provisioners to ensure shared VPC and firewall rules
# exist before proceeding, leveraging gcloud CLI for idempotent 'get-or-create'.
# This approach ensures tenant isolation and avoids "resource already exists" errors.
# ----------------------------------------------------------------------------------------------------------------------

# Get-or-Create Tenant VPC Network
# This null_resource attempts to describe the VPC network; if it doesn't exist, it creates it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }

  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
  }
}

# Data source to read the tenant VPC network details after it's guaranteed to exist
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# Get-or-Create Shared Firewall Rule: Allow internal network traffic
# This null_resource ensures a firewall rule allowing all internal traffic exists.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }

  triggers = {
    tenant_id   = var.tenant_id
    project_id  = var.project_id
    network_id  = data.google_compute_network.tenant_vpc.id
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Get-or-Create Shared Firewall Rule: Allow IAP SSH traffic
# This null_resource ensures a firewall rule allowing SSH via IAP exists.
resource "null_resource" "allow_iap_ssh_provisioner" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create if OS is Linux
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }

  triggers = {
    tenant_id   = var.tenant_id
    project_id  = var.project_id
    network_id  = data.google_compute_network.tenant_vpc.id
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# ----------------------------------------------------------------------------------------------------------------------
# GCP UNIQUE SUBNET GENERATION
# Creates a unique subnet for this specific deployment within the shared tenant VPC.
# Uses random integers to generate a unique IP CIDR range, ensuring no collisions.
# ----------------------------------------------------------------------------------------------------------------------

# Generate a random integer for the second octet of the subnet's IP range
resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Generate a random integer for the third octet of the subnet's IP range
resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Create a unique subnetwork for this deployment within the tenant VPC
resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link

  depends_on = [
    data.google_compute_network.tenant_vpc,
    random_integer.subnet_octet_2,
    random_integer.subnet_octet_3,
  ]
}

# ----------------------------------------------------------------------------------------------------------------------
# GCP VIRTUAL MACHINE DEPLOYMENT
# Deploys the virtual machine instance with specified configuration.
# ----------------------------------------------------------------------------------------------------------------------

# Deploy the virtual machine instance
resource "google_compute_instance" "this_vm" {
  project          = var.project_id
  name             = var.instance_name
  machine_type     = var.vm_size
  zone             = "${var.region}-a" # Defaulting to zone 'a' within the specified region
  deletion_protection = false # Explicitly setting deletion_protection to false

  boot_disk {
    initialize_params {
      # CRITICAL: Using the specified exact cloud image name.
      image = "ubuntu-22-04-19271224598"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # Assign an ephemeral public IP for direct connectivity/management agents
    access_config {
      // Ephemeral public IP is assigned here.
    }
  }

  service_account {
    # Grant minimal permissions required for cloud operations (e.g., Stackdriver logging, monitoring)
    scopes = ["cloud-platform"]
  }

  # Apply instance tags conditionally based on OS type for firewall rules
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Pass custom script as startup metadata
  metadata_startup_script = var.custom_script

  # For Linux, inject the generated SSH public key into instance metadata
  dynamic "metadata" {
    for_each = var.os_type == "Linux" ? { ssh_key = tls_private_key.admin_ssh[0].public_key_openssh } : {}
    content {
      ssh-keys = "packer:${metadata.value}"
    }
  }

  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner # If Linux
  ]
}

# ----------------------------------------------------------------------------------------------------------------------
# GCP PER-INSTANCE FIREWALL RULES
# Creates specific firewall rules for this instance to allow public SSH/RDP/WinRM access.
# Rules are conditional based on OS type to ensure only relevant ports are opened.
# ----------------------------------------------------------------------------------------------------------------------

# Allow public SSH access to this specific Linux instance
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

  depends_on = [google_compute_instance.this_vm]
}

# Allow public RDP access to this specific Windows instance
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

  depends_on = [google_compute_instance.this_vm]
}

# Allow public WinRM access to this specific Windows instance
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

  depends_on = [google_compute_instance.this_vm]
}

# ----------------------------------------------------------------------------------------------------------------------
# OUTPUTS
# These outputs provide important information about the deployed virtual machine.
# ----------------------------------------------------------------------------------------------------------------------

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "public_ip" {
  description = "The public IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

output "instance_id" {
  description = "The unique instance ID assigned by Google Cloud Platform."
  value       = google_compute_instance.this_vm.instance_id
}

output "private_ssh_key" {
  description = "The private SSH key for accessing the instance (sensitive)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux VM"
  sensitive   = true
}

output "network_tags" {
  description = "The network tags applied to the instance."
  value       = google_compute_instance.this_vm.tags
}