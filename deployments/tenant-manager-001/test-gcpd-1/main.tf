# Terraform configuration block to define required providers and their versions.
# This ensures that the correct provider plugins are downloaded and used.
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
# CRITICAL: The 'project' attribute is intentionally omitted here as per instructions,
# relying on the default project configured via `gcloud` or environment variables.
provider "google" {
  region = var.region
}

# --- Input Variables ---
# Terraform variables are declared here to make the script flexible and prevent
# interactive prompts. Each variable has a default value populated from the JSON configuration.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpd-1"
}

variable "region" {
  description = "The GCP region where the resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "A custom script to be executed on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used in resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "image_name" {
  description = "The exact name of the custom OS image to use for the VM."
  type        = string
  default     = "ubuntu-22-04-19271224598"
}

# --- Data Sources ---

# Data source to retrieve information about the current Google Cloud project.
# This is necessary for constructing gcloud commands that require the project ID.
data "google_project" "project" {}

# --- SSH Key Pair Generation ---

# Generates a new RSA private key for SSH access.
# This key pair will be used for secure administrative access to the VM.
# CRITICAL: The 'comment' argument is explicitly forbidden and not included.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Tenant Networking and Firewall Rules (Get-or-Create Idempotent Pattern) ---

# Resource to generate a random integer for unique subnet creation.
# This helps prevent IP range collisions in multi-tenant environments.
resource "random_integer" "subnet_octet" {
  min = 2  # Start from 2 to avoid common network ranges
  max = 254
}

# Null resource to provision the tenant VPC network using gcloud.
# This implements a "get-or-create" pattern, ensuring the VPC exists before proceeding.
# It checks if the network exists; if not, it creates it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to retrieve details of the tenant VPC network.
# CRITICAL: 'depends_on' ensures this runs only after the `null_resource` has completed,
# guaranteeing the VPC is present.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to provision the 'allow-internal' firewall rule using gcloud.
# This rule allows all internal traffic within the VPC.
# It checks if the rule exists; if not, it creates it.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8 --description=\"Allow all internal traffic within the tenant VPC\""
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Depends on VPC existing
}

# Null resource to provision the 'allow-iap-ssh' firewall rule using gcloud.
# This rule allows SSH access via Google's Identity-Aware Proxy (IAP).
# It checks if the rule exists; if not, it creates it.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap --description=\"Allow SSH via IAP for instances tagged 'ssh-via-iap'\""
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Depends on VPC existing
}

# Creates a unique subnetwork for this specific VM deployment.
# This ensures tenant isolation and avoids IP range conflicts.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# --- Virtual Machine Instance ---

# Main resource block to deploy the Google Compute Engine virtual machine.
# Named "this_vm" as per instructions.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Using a specific zone within the region
  tags         = ["ssh-via-iap"]  # Tag for IAP firewall rule
  deletion_protection = false # CRITICAL: Explicitly set to false as per instructions.

  # CRITICAL: OMITTING 'project' attribute as per instructions.

  # Boot disk configuration, using the specified custom image name.
  boot_disk {
    initialize_params {
      image = var.image_name
      type  = "pd-standard" # Standard persistent disk
    }
  }

  # Network interface configuration.
  # CRITICAL STRUCTURE: 'access_config {}' must be directly inside 'network_interface'.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: An empty access_config block assigns an ephemeral public IP address.
    access_config {}
  }

  # Service account configuration for the VM.
  # CRITICAL STRUCTURE: This block must not contain an access_config.
  service_account {
    scopes = ["cloud-platform"] # Allows the VM to access all Cloud Platform services
  }

  # SSH keys for administrative access.
  # For GCP, SSH keys are provided via instance metadata.
  metadata = {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # User data script for instance initialization.
  # For GCP, this is passed via 'metadata_startup_script'.
  metadata_startup_script = var.custom_script

  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner
  ]
}

# --- Outputs ---

# Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the generated private SSH key.
# CRITICAL: This output is marked as sensitive to prevent it from being displayed
# in plain text in Terraform logs or state files.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}