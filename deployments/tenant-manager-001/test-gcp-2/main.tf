# main.tf

# Terraform Configuration Block
# Specifies the required providers and their versions.
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

# Google Cloud Platform Provider Configuration
# Configures the Google Cloud provider.
# CRITICAL: The 'project' attribute is intentionally omitted as per instructions.
provider "google" {
  region = var.region
}

# Variable Declaration Block
# Defines all necessary input variables for the deployment, with default values
# directly extracted from the provided JSON configuration or specific instructions.

# Instance name for the virtual machine
variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcp-2"
}

# GCP region where the resources will be deployed
variable "region" {
  description = "Google Cloud region for resource deployment."
  type        = string
  default     = "us-central1"
}

# Machine type (size) for the virtual machine
variable "vm_size" {
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

# Custom script to be executed on instance startup (user data)
variable "custom_script" {
  description = "Custom script to run on instance startup. For GCP, this is passed as metadata_startup_script."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Identifier for the tenant, used for naming resources to ensure isolation
variable "tenant_id" {
  description = "Unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

# The specific custom image name to be used for the VM.
# CRITICAL: This value is taken directly from the instructions, not the JSON's osImageId.
variable "gcp_image_name" {
  description = "The exact custom image name for the VM in GCP."
  type        = string
  default     = "ubuntu-22-04-19271224598"
}

# Resource to generate a unique random integer for subnet CIDR block.
# This helps in creating non-overlapping private IP ranges for subnets.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Resource to generate a new SSH private key locally.
# This key will be used for secure access to the VM.
# CRITICAL: The 'comment' argument is FORBIDDEN as per instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# GCP Network Configuration for Tenant Isolation

# Resource: Tenant VPC Network
# Creates a dedicated Virtual Private Cloud (VPC) network for the tenant.
# auto_create_subnetworks is set to false to allow manual subnet creation and control.
# CRITICAL: The 'project' attribute is intentionally omitted as per instructions.
resource "google_compute_network" "tenant_vpc" {
  name                    = "pmos-tenant-${var.tenant_id}-vpc"
  auto_create_subnetworks = false
}

# Resource: Firewall Rule for Internal Traffic
# Allows all protocols for intra-tenant communication within the tenant VPC.
# CRITICAL: The 'project' attribute is intentionally omitted as per instructions.
resource "google_compute_firewall" "allow_internal" {
  name    = "pmos-tenant-${var.tenant_id}-allow-internal"
  network = google_compute_network.tenant_vpc.name

  allow {
    protocol = "all"
  }

  source_ranges = ["10.0.0.0/8"] # Covers all possible tenant subnets
}

# Resource: Firewall Rule for IAP SSH Access
# Allows secure SSH access to instances tagged with 'ssh-via-iap' from Google's IAP service.
# CRITICAL: The 'project' attribute is intentionally omitted as per instructions.
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "pmos-tenant-${var.tenant_id}-allow-iap-ssh"
  network = google_compute_network.tenant_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] # Google IAP source range
  target_tags   = ["ssh-via-iap"]
}

# Resource: Unique Subnet for This Deployment
# Creates a new subnet within the tenant VPC with a dynamically generated IP range.
# This ensures that concurrent deployments do not suffer from IP conflicts.
# CRITICAL: The 'project' attribute is intentionally omitted as per instructions.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = google_compute_network.tenant_vpc.self_link
}

# Google Compute Instance Resource
# Defines the virtual machine instance to be deployed.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Deploying to zone 'a' within the specified region.
  deletion_protection = false # CRITICAL: Set to false as per instructions.
  # CRITICAL: The 'project' attribute is intentionally omitted as per instructions.

  # Boot Disk Configuration
  boot_disk {
    initialize_params {
      image = var.gcp_image_name # CRITICAL: Using the explicitly provided image name.
    }
  }

  # Network Interface Configuration
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: Empty access_config block assigns an ephemeral public IP for agent connectivity.
    access_config {}
  }

  # Metadata for SSH keys and startup script.
  metadata = {
    ssh-keys       = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
    startup-script = var.custom_script # CRITICAL: Using metadata_startup_script for GCP.
  }

  # Tags applied to the instance for firewall rules (e.g., IAP SSH).
  tags = ["ssh-via-iap"]

  # Service account configuration for the instance.
  service_account {
    scopes = ["cloud-platform"] # CRITICAL: Required for instance to interact with GCP services.
  }
}

# Output Block: Private IP Address
# Exposes the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed VM."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output Block: Instance ID
# Exposes the cloud provider's native instance ID of the deployed virtual machine.
output "instance_id" {
  description = "The cloud provider's native instance ID of the VM."
  value       = google_compute_instance.this_vm.instance_id
}

# Output Block: Private SSH Key
# Exposes the generated private SSH key. Marked as sensitive to prevent logging.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}