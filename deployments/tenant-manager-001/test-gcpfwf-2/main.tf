# This Terraform script deploys a Virtual Machine on Google Cloud Platform.
# It includes robust networking setup with get-or-create patterns for shared resources,
# dynamic subnet creation, conditional firewall rules, and SSH key management.

# --- Providers Configuration ---
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

# Configure the Google Cloud provider. The 'project' attribute is omitted as per instructions,
# relying on the default project configured in the environment (e.g., via gcloud CLI).
provider "google" {
  region = var.region
}

# --- Input Variables ---

# The name of the virtual machine instance.
variable "instance_name" {
  type        = string
  description = "Name of the VM instance."
  default     = "test-gcpfwf-2"
}

# The Google Cloud region where resources will be deployed.
variable "region" {
  type        = string
  description = "Google Cloud region."
  default     = "us-central1"
}

# The machine type (e.g., e2-micro, n1-standard-1) for the VM.
variable "vm_size" {
  type        = string
  description = "Size/type of the virtual machine."
  default     = "e2-micro"
}

# A unique identifier for the tenant, used in resource naming for isolation.
variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant."
  default     = "tenant-manager-001"
}

# The operating system type (Linux or Windows) of the VM.
# This dictates SSH key generation and specific firewall rules.
variable "os_type" {
  type        = string
  description = "Operating System type (Linux or Windows)."
  default     = "Linux"
}

# Optional custom script to run on instance startup.
variable "custom_script" {
  type        = string
  description = "Custom script to run on instance startup (user data)."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# CRITICAL: The exact cloud image name to use for deployment.
# This value is provided directly and overrides any other image IDs in the JSON.
variable "image_name" {
  type        = string
  description = "The exact cloud image name for the VM."
  default     = "ubuntu-22-04-19271224598"
}


# --- GCP Shared Network & Firewall Resources (Get-or-Create Idempotent Logic) ---

# Data source to retrieve the current Google Cloud project ID.
data "google_project" "project" {}

# Null resource to idempotently provision the tenant VPC network using gcloud CLI.
# It attempts to describe the network first; if it doesn't exist, it creates it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant VPC network data after it's ensured to exist.
data "google_compute_network" "tenant_vpc" {
  name        = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is provisioned before attempting to read
}

# Null resource to idempotently provision the shared internal firewall rule.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Depends on VPC existing
}

# Null resource to idempotently provision the shared IAP SSH firewall rule.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Depends on VPC existing
}

# Random integer for generating a unique subnet IP range to avoid collisions.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a unique subnetwork for this deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name        = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region      = var.region
  network     = data.google_compute_network.tenant_vpc.self_link
  depends_on  = [null_resource.vpc_provisioner] # Ensure VPC is provisioned
}

# --- SSH Key Pair Generation (for Linux VMs) ---

# Generate a new private/public SSH key pair.
# The 'comment' argument is explicitly forbidden by instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Per-Instance Firewall Rules (Conditional) ---

# Firewall rule to allow public SSH access to this specific Linux instance.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]
  depends_on    = [null_resource.vpc_provisioner]
}

# Firewall rule to allow public RDP access to this specific Windows instance.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]
  depends_on    = [null_resource.vpc_provisioner]
}

# Firewall rule to allow public WinRM access to this specific Windows instance.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
  depends_on    = [null_resource.vpc_provisioner]
}


# --- Virtual Machine Deployment ---

# Primary compute resource for the virtual machine.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Deploy to specific zone within the region
  deletion_protection = false # As per instruction

  # CRITICAL: Omit 'project' attribute here.
  # project = data.google_project.project.project_id

  boot_disk {
    initialize_params {
      image = var.image_name # CRITICAL: Use the exact specified image name
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: No 'access_config' block to prevent assigning a public IP,
    # relying on IAP for SSH connectivity.
  }

  # Apply conditional tags for firewall rules and IAP access.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Service account with cloud-platform scopes for instance identity and access.
  service_account {
    email  = "default" # Use the default compute service account
    scopes = ["cloud-platform"]
    # No 'access_config' block here either.
  }

  # Add SSH public key to instance metadata for Linux VMs.
  # The 'packer' user is a common convention for automated SSH access.
  metadata = var.os_type == "Linux" ? {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  } : {}

  # Pass custom script as startup script metadata.
  metadata_startup_script = var.custom_script

  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm,
  ]
}

# --- Outputs ---

# Expose the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the VM."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Expose the network tags associated with the virtual machine.
output "network_tags" {
  description = "Network tags applied to the VM instance."
  value       = google_compute_instance.this_vm.tags
}

# Expose the generated private SSH key for Linux VMs.
# This output is marked as sensitive to prevent it from being displayed in plaintext in logs.
output "private_ssh_key" {
  description = "The private SSH key generated for administrative access (sensitive)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}