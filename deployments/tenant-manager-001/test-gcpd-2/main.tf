# This Terraform script deploys a Virtual Machine on Google Cloud Platform.
# It includes robust features for tenant isolation, network setup, SSH key management,
# and custom startup scripts, following best practices for secure and repeatable deployments.

# --- Providers Configuration ---
# Required providers for GCP infrastructure, SSH key generation, and random value generation.
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

# Configure the Google Cloud provider.
# The 'project' attribute is intentionally omitted here and from the instance resource
# to align with tenant isolation requirements, allowing the project to be inherited from
# the gcloud CLI configuration or service account.
provider "google" {
  region = var.region
}

# --- Input Variables ---
# These variables allow easy customization of the deployment.
# Default values are sourced directly from the provided JSON configuration.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpd-2"
}

variable "region" {
  description = "The GCP region where the instance will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "A custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for naming shared network resources."
  type        = string
  default     = "tenant-manager-001"
}

# --- SSH Key Pair Generation ---
# Generates a new RSA SSH key pair for administrative access to the VM.
# The private key is outputted as sensitive data.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # The 'comment' argument is explicitly forbidden by instructions and is not included.
}

# --- GCP Project Data Source ---
# Retrieves information about the current Google Cloud project.
# This is crucial for constructing gcloud CLI commands that target the correct project.
data "google_project" "project" {}

# --- Tenant VPC Network Get-or-Create ---
# Implements an idempotent "get-or-create" pattern for the shared tenant VPC network.
# It first attempts to describe the network; if it doesn't exist, it creates it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
    interpreter = ["bash", "-c"]
  }
}

# Data source to read the provisioned tenant VPC network.
# Explicitly depends on the 'vpc_provisioner' to ensure the network is created before being read.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# --- Firewall Rules Get-or-Create ---
# Idempotently provisions firewall rules required for tenant isolation and management.

# Rule for allowing all internal traffic within the 10.0.0.0/8 range.
resource "null_resource" "allow_internal_provisioner" {
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating rules.
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
    interpreter = ["bash", "-c"]
  }
}

# Rule for allowing SSH access via Google Cloud IAP (Identity-Aware Proxy).
resource "null_resource" "allow_iap_ssh_provisioner" {
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating rules.
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
    interpreter = ["bash", "-c"]
  }
}

# --- Unique Subnet Creation ---
# Creates a unique subnetwork for this specific VM deployment within the tenant VPC.
# Uses a random integer to generate a distinct IP CIDR range, enhancing isolation and avoiding conflicts.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  # The 'keepers' argument ensures that a new random integer is generated if the instance_name changes.
  keepers = {
    instance_name = var.instance_name
  }
}

resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [null_resource.vpc_provisioner] # Ensure VPC exists before creating the subnet.
}

# --- Virtual Machine Deployment ---
# Deploys the primary compute resource, named "this_vm" as per instructions.
resource "google_compute_instance" "this_vm" {
  name                = var.instance_name
  machine_type        = var.vm_size
  zone                = "${var.region}-a" # Append '-a' to region for a specific zone, e.g., us-central1-a.
  deletion_protection = false              # Explicitly set to false.

  # Apply the IAP SSH tag for secure SSH access.
  tags = ["ssh-via-iap"]

  # Configure the boot disk with the specified custom image.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Exact image name provided in instructions.
    }
  }

  # Configure the network interface.
  # The instance is attached to the newly created unique subnet.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: This empty block assigns an ephemeral public IP address.
    # It must be placed directly within the network_interface block.
    access_config {}
  }

  # Configure the service account with necessary scopes for cloud platform access.
  # CRITICAL: This block must NOT contain an access_config.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Provide the SSH public key via instance metadata for initial access.
  # 'ssh-keys' metadata entry is formatted as 'user:public_key'.
  metadata = {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # Pass the custom script to be executed on instance startup.
  # For GCP, 'metadata_startup_script' is used directly.
  metadata_startup_script = var.custom_script

  # Ensure network resources are ready before creating the instance.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# --- Outputs ---
# Exposes key information about the deployed virtual machine.

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The unique instance ID assigned by Google Cloud Platform."
  value       = google_compute_instance.this_vm.instance_id
}

output "private_ssh_key" {
  description = "The private SSH key for accessing the virtual machine."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # Mark as sensitive to prevent accidental exposure in logs.
}