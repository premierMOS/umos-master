# This Terraform configuration deploys a virtual machine on Google Cloud Platform.
# It includes robust networking for tenant isolation, SSH key management,
# and conditional firewall rules.

# --- Provider Configuration ---
# Configure the Google Cloud provider.
# The 'project' attribute is intentionally omitted as per instructions,
# expecting it to be set via environment variables (e.g., GOOGLE_PROJECT)
# or gcloud configuration.
provider "google" {
  region = var.region
  # project = "<YOUR_GCP_PROJECT_ID>" # Omitted as per CRITICAL INSTRUCTIONS
}

# Configure required providers and their versions.
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

# --- Input Variables ---
# These variables allow customization of the VM deployment.
# Default values are set directly from the provided JSON configuration.

variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpfwg-2"
}

variable "region" {
  description = "GCP region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used in naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type (Linux or Windows), used for conditional logic."
  type        = string
  default     = "Linux" # Derived from os.type in JSON
}

variable "custom_script" {
  description = "Custom script to execute on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Data Sources ---

# Retrieve the current GCP project ID. Required for gcloud commands.
data "google_project" "project" {}

# Data source to read the tenant VPC network, ensuring it exists after the null_resource.
data "google_compute_network" "tenant_vpc" {
  name    = "pmos-tenant-${var.tenant_id}-vpc"
  project = data.google_project.project.project_id
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

# --- Resources ---

# Generate an SSH key pair for Linux instances.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
  # The 'comment' argument is forbidden by CRITICAL INSTRUCTION.
}

# Random integer for dynamic subnet CIDR block generation.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Null resource to idempotently provision the tenant VPC using gcloud CLI.
# This ensures the VPC exists before other resources try to use it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Null resource to idempotently provision the shared 'allow-internal' firewall rule.
resource "null_resource" "allow_internal_provisioner" {
  depends_on = [
    null_resource.vpc_provisioner
  ]
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
}

# Null resource to idempotently provision the shared 'allow-iap-ssh' firewall rule.
resource "null_resource" "allow_iap_ssh_provisioner" {
  depends_on = [
    null_resource.vpc_provisioner
  ]
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
}

# Create a unique subnetwork for this deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  # Explicitly depend on VPC and shared firewall rules to ensure order of operations
  depends_on = [
    null_resource.vpc_provisioner,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner
  ]
}

# Main virtual machine instance resource.
resource "google_compute_instance" "this_vm" {
  name                 = var.instance_name
  machine_type         = var.vm_size
  zone                 = "${var.region}-c" # Using a default zone in the region
  deletion_protection  = false             # As per CRITICAL INSTRUCTIONS

  # Project attribute omitted as per CRITICAL INSTRUCTIONS
  # project = data.google_project.project.project_id

  # Boot disk configuration.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # Exact image name as per CRITICAL INSTRUCTIONS
    }
  }

  # Network interface configuration.
  # No 'access_config' block as per CRITICAL INSTRUCTIONS, relying on IAP for connectivity.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # No 'access_config' block should be present here.
  }

  # Service account for the VM, granting necessary permissions.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Conditional metadata for SSH keys (Linux) and startup script.
  metadata = merge(
    var.os_type == "Linux" ? {
      "ssh-keys" = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
    } : {},
    var.custom_script != "" ? {
      "startup-script" = var.custom_script # Use metadata_startup_script
    } : {}
  )

  # Conditional instance tags based on OS type for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Explicit dependency on the subnet creation
  depends_on = [
    google_compute_subnetwork.this_subnet
  ]
}

# --- Per-Instance Firewall Rules (conditional based on OS Type) ---

# Firewall rule to allow public SSH access to this specific Linux instance.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]
  depends_on = [
    google_compute_instance.this_vm
  ]
}

# Firewall rule to allow public RDP access to this specific Windows instance.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]
  depends_on = [
    google_compute_instance.this_vm
  ]
}

# Firewall rule to allow public WinRM access to this specific Windows instance.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
  depends_on = [
    google_compute_instance.this_vm
  ]
}

# --- Outputs ---
# Expose key information about the deployed virtual machine.

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The unique ID assigned to the virtual machine by GCP."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "List of network tags applied to the virtual machine."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The private SSH key (PEM format) generated for Linux instances."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true
}