terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "~> 5.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# --- Terraform Variables ---
# All key configuration values are defined as variables with default values
# directly from the provided JSON, preventing interactive prompts.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwh-3"
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

variable "tenant_id" {
  description = "A unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (e.g., Linux, Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "A custom script to be executed on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "cloud_image_name" {
  description = "The exact name of the custom image to use for deployment."
  type        = string
  default     = "ubuntu-22-04-19271224598" # CRITICAL: Explicitly provided image name
}

# --- GCP Provider Configuration ---
# The project is omitted here and will be picked up from the environment or gcloud config.
provider "google" {
  region = var.region
}

# --- Data Sources ---

# Get the current Google Cloud project ID for gcloud commands.
data "google_project" "project" {}

# --- Tenant-Shared Networking (Get-or-Create Idempotent Logic) ---
# These resources ensure that a shared VPC network and base firewall rules
# exist for the tenant, creating them if they don't, using gcloud.

# Provisioner to get or create the tenant-specific VPC network.
# This ensures the network exists before any resources try to use it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to retrieve details of the tenant VPC network.
# Explicit dependency ensures the VPC is provisioned first.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Provisioner to get or create the shared firewall rule for internal traffic (10.0.0.0/8).
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Provisioner to get or create the shared firewall rule for IAP SSH (tcp:22 from IAP source ranges).
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Unique Subnet for this Deployment ---

# Generates a random integer for a unique subnet IP range to avoid collisions.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  # Keepers ensure the random value changes if instance_name changes
  keepers = {
    instance_name = var.instance_name
  }
}

# Create a new, unique subnetwork for this specific virtual machine deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link

  depends_on = [
    null_resource.vpc_provisioner,
  ]
}

# --- SSH Key Pair Generation (for Linux deployments) ---
# Generates a new SSH key pair locally using tls provider for Linux instances.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: Do NOT include 'comment' argument here as it's not supported by tls_private_key.
}

# --- Virtual Machine Deployment ---

# The primary compute resource for the virtual machine.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Deploy to a specific zone within the region
  
  # CRITICAL: OMIT project attribute from the instance block.
  # CRITICAL: deletion_protection MUST be false.
  deletion_protection = false

  # Boot disk configuration, using the specified custom image.
  boot_disk {
    initialize_params {
      image = var.cloud_image_name # CRITICAL: Use the exact cloud image name provided.
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: NO 'access_config' block for public IP to avoid quotas and use IAP.
  }

  # Service account configuration for instance permissions.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Startup script for instance initialization (user data).
  metadata_startup_script = var.custom_script

  # Metadata for SSH access (for Linux instances).
  dynamic "metadata" {
    for_each = var.os_type == "Linux" ? { ssh-keys = tls_private_key.admin_ssh[0].public_key_openssh } : {}
    content {
      ssh-keys = "packer:${metadata.value["ssh-keys"]}"
    }
  }

  # Tags for firewall rules and other network access configurations.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  depends_on = [
    null_resource.vpc_provisioner,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
    google_compute_subnetwork.this_subnet,
  ]
}

# --- Per-Instance Firewall Rules ---
# These firewall rules are specific to this deployment, allowing public access
# based on the OS type and instance name tags.

# Firewall rule to allow public SSH access for Linux instances.
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

  depends_on = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public RDP access for Windows instances.
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

  depends_on = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public WinRM access for Windows instances.
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

  depends_on = [data.google_compute_network.tenant_vpc]
}


# --- Outputs ---

# Exposes the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The Google Cloud instance ID of the virtual machine."
  value       = google_compute_instance.this_vm.instance_id
}

# Exposes the network tags applied to the instance.
output "network_tags" {
  description = "The network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

# Exposes the generated private SSH key, marked as sensitive.
# This output is only available if an SSH key was generated (i.e., for Linux VMs).
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (if Linux)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true
}