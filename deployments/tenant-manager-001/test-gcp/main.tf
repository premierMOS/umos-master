# Required providers for Google Cloud Platform and TLS (for SSH key generation)
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Specify a compatible version for the Google provider
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Specify a compatible version for the TLS provider
    }
  }
}

# Google Cloud Platform Provider Configuration
# CRITICAL GCP INSTRUCTION: The 'project' attribute is deliberately omitted here.
# It is automatically inherited from the configured credentials (e.g., GOOGLE_PROJECT, gcloud config).
provider "google" {
  region = var.region
}

# Terraform Variables Block
# All variables are declared with 'default' values set directly from the provided JSON configuration.
# This ensures the script is non-interactive and ready to use.

variable "instance_name" {
  description = "The desired name for the virtual machine instance."
  type        = string
  default     = "test-gcp"
}

variable "region" {
  description = "The GCP region where the virtual machine will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "An identifier for the tenant or organizational unit."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A base64 encoded custom script to run on the instance during its first boot (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Resource to generate an SSH private and public key pair.
# This key pair will be used for secure SSH access to the Linux virtual machine.
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Primary Google Compute Instance Resource
# This block defines the virtual machine to be deployed on Google Cloud Platform.
resource "google_compute_instance" "this_vm" {
  # Name of the virtual machine instance.
  name         = var.instance_name
  # Machine type (size) of the VM, e.g., e2-micro.
  machine_type = var.vm_size
  # The specific zone where the VM instance will be created.
  # GCP instances require a zone. We derive a default zone by appending '-a' to the specified region.
  zone         = "${var.region}-a"

  # CRITICAL GCP INSTRUCTION:
  # The 'project' attribute is omitted as per instructions; it's inherited from the provider configuration.
  # project = "your-gcp-project-id" # OMITTED as per instructions

  # Boot Disk Configuration
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION:
      # Use the exact and complete custom image name provided.
      image = "fedora-39-19346783265"
    }
  }

  # Network Interface Configuration
  network_interface {
    # Using the 'default' network. For production environments, a custom VPC network is recommended.
    network = "default"
    # CRITICAL NETWORKING REQUIREMENT:
    # An empty 'access_config {}' block assigns an ephemeral public IP address to the instance.
    # This enables outbound internet access and allows inbound SSH if firewall rules permit.
    access_config {}
  }

  # Metadata for the instance, including SSH keys for administrative access.
  metadata = {
    # For Linux deployments, inject the generated public SSH key into the metadata.
    # This allows the 'packer' user (or similar, depending on OS) to SSH in.
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # USER DATA/CUSTOM SCRIPT:
  # For GCP, 'metadata_startup_script' is used to execute the custom script on instance startup.
  metadata_startup_script = var.custom_script

  # CRITICAL GCP INSTRUCTION:
  # The 'service_account' block with 'cloud-platform' scope enables necessary APIs for secure connectivity
  # and allows the instance to interact with other GCP services.
  service_account {
    scopes = ["cloud-platform"]
  }

  # CRITICAL GCP INSTRUCTION:
  # 'deletion_protection = false' allows the instance to be deleted without manual intervention.
  deletion_protection = false

  # Optional labels for resource organization and billing.
  labels = {
    tenant_id = var.tenant_id
    # Add any other desired labels, e.g., environment = "dev", app = "web"
  }
}

# Output Block: Exposes the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output Block: Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Output Block: Exposes the generated private SSH key.
# CRITICAL: This output is marked as sensitive to prevent the private key from being displayed
# in plain text in Terraform logs or state output.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}