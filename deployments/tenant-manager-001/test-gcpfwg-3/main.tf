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

# No 'project' attribute in the provider block per critical instruction.
provider "google" {
  region = var.region
}

# Declare Terraform variables with default values from the JSON configuration
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwg-3"
}

variable "region" {
  description = "The GCP region where the resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "The tenant identifier for resource naming and isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "A custom script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- GCP Tenant Isolation and Networking ---

# Data source to retrieve the current GCP project ID
data "google_project" "project" {}

# Get-or-create tenant VPC network using a null_resource and local-exec provisioner
# This ensures the network exists before proceeding, creating it if it doesn't.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant VPC network, depends on its provisioning
data "google_compute_network" "tenant_vpc" {
  depends_on = [null_resource.vpc_provisioner]
  name       = "pmos-tenant-${var.tenant_id}-vpc"
}

# Get-or-create shared firewall rule for internal traffic
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
}

# Get-or-create shared firewall rule for IAP SSH access
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
}

# Random integer to generate a unique third octet for the subnet IP range
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a unique subnetwork for this deployment within the tenant VPC
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
}

# --- SSH Key Pair Generation (for Linux instances) ---

# Generate a new SSH private key for instance access
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: Do NOT add 'comment' argument as it's forbidden.
}

# --- Per-Instance Firewall Rules ---

# Firewall rule to allow public SSH access to this specific instance
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
}

# Firewall rule to allow public RDP access to this specific instance (for Windows)
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
}

# Firewall rule to allow public WinRM access to this specific instance (for Windows)
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
}


# --- Virtual Machine Deployment ---

# Deploy the virtual machine instance
resource "google_compute_instance" "this_vm" {
  # CRITICAL: OMIT 'project' attribute
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Appending '-a' to the region for a default zone.
  # CRITICAL: deletion_protection MUST be false
  deletion_protection = false

  # Boot disk configuration using the specified custom image name
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION: Use the exact specified image name
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network interface attached to the newly created subnet
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: NO 'access_config' block to avoid public IP address
  }

  # Service account with cloud-platform scopes for full API access
  service_account {
    scopes = ["cloud-platform"]
  }

  # Instance tags for firewall rules and other metadata
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for SSH keys (Linux only) and startup script
  metadata = merge(
    var.os_type == "Linux" ? { "ssh-keys" : "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" } : {},
    var.custom_script != "" ? { "startup-script" : var.custom_script } : {}
  )
}

# --- Outputs ---

# Output the private IP address of the created VM
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the network tags applied to the instance
output "network_tags" {
  description = "Network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key (sensitive)
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance (sensitive)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A for Windows instances"
  sensitive   = true
}