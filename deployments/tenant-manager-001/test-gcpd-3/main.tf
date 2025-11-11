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

# Google Cloud Platform provider configuration.
# CRITICAL: The 'project' attribute is intentionally omitted as per instructions,
# expecting it to be configured via environment variables (e.g., GOOGLE_PROJECT)
# or gcloud CLI default configuration.
provider "google" {
  region = var.region
}

# --- Terraform Variables ---

# Variable for the virtual machine instance name.
variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpd-3"
}

# Variable for the Google Cloud region where resources will be deployed.
variable "region" {
  description = "Google Cloud region for the deployment."
  type        = string
  default     = "us-central1"
}

# Variable for the machine type (VM size) of the virtual machine.
variable "vm_size" {
  description = "Machine type for the virtual machine."
  type        = string
  default     = "e2-micro"
}

# Variable for a custom startup script to be executed on the VM.
variable "custom_script" {
  description = "Custom script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Variable for the tenant identifier, used to name shared tenant-specific resources.
variable "tenant_id" {
  description = "Identifier for the tenant, used for naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

# CRITICAL IMAGE NAME INSTRUCTION:
# Variable explicitly defining the complete cloud image name to be used.
variable "image_name" {
  description = "The exact name of the custom OS image to use for the VM."
  type        = string
  default     = "ubuntu-22-04-19271224598"
}

# --- Data Sources ---

# Data source to retrieve the current Google Cloud project ID.
# This is necessary for gcloud commands executed via local-exec.
data "google_project" "project" {}

# Data source to retrieve the tenant-specific VPC network after it has been provisioned.
# This allows other resources to reference the VPC by its self_link.
data "google_compute_network" "tenant_vpc" {
  name = "pmos-tenant-${var.tenant_id}-vpc"
  # CRITICAL: Explicitly depend on the null_resource to ensure the VPC exists
  # before Terraform attempts to read its data.
  depends_on = [null_resource.vpc_provisioner]
}

# --- SSH Key Pair Generation ---

# CRITICAL FOR LINUX DEPLOYMENTS ONLY:
# Generates a new RSA SSH key pair (private and public keys).
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
  # It is FORBIDDEN to include a 'comment' argument here.
}

# --- GCP Networking, Connectivity & Tenant Isolation ---

# Resource to generate a random number (octet) for the subnet's IP range.
# This helps ensure that each deployment creates a unique subnet CIDR,
# preventing IP conflicts when multiple instances are deployed within the same VPC.
resource "random_integer" "subnet_octet" {
  min = 2  # Start from 2 to avoid common network ranges like 10.0.0.0/24
  max = 254
}

# CRITICAL GCP NETWORKING: Get-or-Create Tenant VPC Network.
# This null_resource executes a local gcloud command to provision the tenant VPC.
# The command is idempotent: it first tries to describe the network, and if it doesn't
# exist (indicated by '||'), it proceeds to create it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# CRITICAL GCP NETWORKING: Get-or-Create Firewall Rule for internal traffic.
# This rule allows all protocols and ports for internal traffic within the
# broad 10.0.0.0/8 private IP range.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  # Ensure the VPC is provisioned before attempting to create firewall rules within it.
  depends_on = [null_resource.vpc_provisioner]
}

# CRITICAL GCP NETWORKING: Get-or-Create Firewall Rule for IAP SSH access.
# This rule specifically allows SSH (TCP port 22) from Google Cloud IAP's IP range
# to instances that have the 'ssh-via-iap' network tag.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  # Ensure the VPC is provisioned before attempting to create firewall rules within it.
  depends_on = [null_resource.vpc_provisioner]
}

# CRITICAL GCP NETWORKING: Create a Unique Subnet for this deployment.
# This ensures tenant isolation and prevents "resource already exists" errors
# on concurrent deployments by using a dynamic IP CIDR range.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  # Ensure all dependent network components (VPC and firewall rules) are ready.
  depends_on = [
    null_resource.vpc_provisioner,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# --- Virtual Machine Deployment ---

# The primary compute resource: a Google Compute Engine virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  # GCP instances require a zone; we append '-a' to the region as a common default.
  zone = "${var.region}-a"

  # CRITICAL: The 'project' attribute is omitted from the instance resource
  # as per instructions, inheriting it from the provider configuration or gcloud defaults.

  # Configure the boot disk for the VM.
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION: Use the exact custom image name provided.
      image = var.image_name
    }
  }

  # CRITICAL STRUCTURE: Network interface configuration for the VM.
  network_interface {
    # The VM is deployed into the unique subnet created for this deployment.
    subnetwork = google_compute_subnetwork.this_subnet.self_link

    # CRITICAL NETWORKING REQUIREMENT:
    # This empty 'access_config' block assigns an ephemeral public IP address to the instance.
    # This is required for cloud management agents (like AWS SSM, though not GCP specific here)
    # and general external connectivity if needed.
    # DO NOT MOVE IT from inside the network_interface block.
    access_config {
    }
  }

  # CRITICAL STRUCTURE: Service account configuration for the VM.
  # This grants the VM appropriate permissions for interacting with GCP services.
  # This block MUST NOT contain an access_config.
  service_account {
    scopes = ["cloud-platform"] # Grants broad access for typical VM operations.
  }

  # CRITICAL FOR LINUX DEPLOYMENTS ONLY: Add the generated public SSH key to instance metadata.
  # This enables SSH access using the corresponding private key.
  metadata = {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # USER DATA/CUSTOM SCRIPT: Pass the custom script to the instance as a startup script.
  # For GCP, metadata_startup_script directly takes the script content.
  metadata_startup_script = var.custom_script

  # CRITICAL GCP NETWORKING: Apply network tags to the instance.
  # The 'ssh-via-iap' tag is crucial for the IAP firewall rule to apply.
  tags = ["ssh-via-iap"]

  # CRITICAL: Explicitly set deletion_protection to false to allow for easy cleanup.
  deletion_protection = false

  # Ensure all dependent network components (subnet, firewall rules) are fully provisioned
  # before attempting to create the virtual machine.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# --- Outputs ---

# Output block named "private_ip" exposing the private IP address of the VM.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output block named "instance_id" exposing the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the deployed virtual machine instance assigned by Google Cloud."
  value       = google_compute_instance.this_vm.instance_id
}

# CRITICAL FOR LINUX DEPLOYMENTS ONLY: Output block named "private_ssh_key".
# This output exposes the generated private SSH key and is marked as sensitive
# to prevent it from being displayed in plaintext in logs or state files (unless explicitly requested).
output "private_ssh_key" {
  description = "The private SSH key generated for administrative access to the VM. CRITICAL: Keep this secure."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}