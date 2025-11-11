# Terraform configuration for Google Cloud Platform (GCP)
# This script deploys a virtual machine instance, including networking and SSH key management.

# --- Provider Configuration ---
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Specify a compatible version
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Specify a compatible version
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # Specify a compatible version
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0" # Specify a compatible version for null_resource
    }
  }
}

# Configure the Google Cloud provider
provider "google" {
  # CRITICAL: The 'project' attribute MUST be OMITTED here as per instructions.
  # Terraform will infer the project from the environment (e.g., GOOGLE_CLOUD_PROJECT, gcloud config).
  region = var.region # Set the deployment region based on the variable
}

# --- Input Variables ---
# These variables define key configuration values for the VM deployment.
# Each variable includes a 'default' value directly from the provided JSON configuration
# to prevent interactive prompts during 'terraform plan' or 'terraform apply'.

variable "instance_name" {
  type        = string
  default     = "test-gcpb-1"
  description = "Name of the virtual machine instance."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region where resources will be deployed (e.g., us-central1)."
}

variable "vm_size" {
  type        = string
  default     = "e2-micro"
  description = "Machine type for the virtual machine instance (e.g., e2-micro)."
}

variable "tenant_id" {
  type        = string
  default     = "tenant-manager-001"
  description = "Unique identifier for the tenant, used for resource naming to ensure isolation."
}

variable "custom_script" {
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to run on instance startup (user data)."
}

# --- SSH Key Pair Generation ---
# Generates a new SSH key pair to securely access the Linux VM.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
  # It is forbidden to include a 'comment' argument in this resource block.
}

# --- GCP Tenant Networking and Isolation ---
# Implements a "get-or-create" pattern for shared tenant resources (VPC and Firewall Rules)
# using 'null_resource' with 'local-exec' and gcloud CLI to ensure idempotency.

# Data source to retrieve the current Google Cloud project ID.
data "google_project" "project" {}

# Null resource to conditionally create the tenant VPC network if it doesn't exist.
# This ensures a unique VPC per tenant while avoiding "resource already exists" errors.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the details of the tenant VPC network.
# CRITICAL: 'depends_on' ensures this data source is refreshed after the 'vpc_provisioner' runs.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = data.google_project.project.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to conditionally create a firewall rule for internal network traffic.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  # Ensure VPC exists before attempting to create firewall rules for it.
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Null resource to conditionally create a firewall rule for SSH access via IAP (Identity-Aware Proxy).
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  # Ensure VPC exists before attempting to create firewall rules for it.
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Generates a random integer for creating a unique IP CIDR range for the subnet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Creates a unique subnetwork for this specific deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  # Explicitly depend on the VPC and random octet to ensure creation order.
  depends_on = [
    data.google_compute_network.tenant_vpc,
    random_integer.subnet_octet,
  ]
}

# --- Virtual Machine Instance Deployment ---
# Deploys the primary virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Deploy into a specific zone within the region

  # CRITICAL: The 'project' attribute MUST be OMITTED as per instructions.
  # Terraform will infer the project from the environment.

  # Configure the boot disk for the instance.
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION: Use the exact specified custom image name.
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Configure the network interface for the instance.
  # CRITICAL NETWORKING REQUIREMENT: Assign to the unique subnet and enable public IP.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: This empty block assigns an ephemeral public IP for the instance. DO NOT MOVE IT.
    access_config {}
  }

  # CRITICAL STRUCTURE: Service account for the VM, providing necessary permissions.
  service_account {
    # 'cloud-platform' scope provides broad access to GCP services.
    scopes = ["cloud-platform"]
  }

  # Metadata for the instance, including SSH keys and startup script.
  metadata = {
    # For GCP, SSH keys are injected via metadata for administration.
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # USER DATA/CUSTOM SCRIPT: For GCP, use 'metadata_startup_script' for custom scripts.
  metadata_startup_script = var.custom_script

  # Tags applied to the instance, used by firewall rules (e.g., IAP SSH).
  tags = ["ssh-via-iap"]

  # CRITICAL: Deletion protection is explicitly set to false as per instructions.
  deletion_protection = false

  # Explicit dependencies to ensure networking resources are ready before the VM is created.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# --- Outputs ---
# These outputs provide important information about the deployed virtual machine.

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID for the virtual machine."
  value       = google_compute_instance.this_vm.instance_id
}

output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # Mark as sensitive to prevent display in plaintext in Terraform output.
}