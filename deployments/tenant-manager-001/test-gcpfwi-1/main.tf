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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# The Google Cloud provider configuration.
# OMITTING 'project' from here to allow it to be inherited from the environment
# or configured at the project level.
provider "google" {
  region = var.region
}

# Terraform variables for key configuration values from the JSON.
# Each variable includes a 'default' value directly from the provided configuration.
variable "instance_name" {
  type        = string
  description = "Name for the virtual machine instance."
  default     = "test-gcpfwi-1"
}

variable "region" {
  type        = string
  description = "Google Cloud region where the VM will be deployed."
  default     = "us-central1"
}

variable "vm_size" {
  type        = string
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  default     = "e2-micro"
}

variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant, used in resource naming."
  default     = "tenant-manager-001"
}

variable "os_type" {
  type        = string
  description = "Operating system type (Linux or Windows)."
  default     = "Linux"
}

variable "custom_script" {
  type        = string
  description = "Custom script to run on instance startup (user data)."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Generate a unique integer for subnet CIDR block to avoid collisions.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  # Ensure a new random number is generated if instance_name changes
  keepers = {
    instance_name = var.instance_name
  }
}

# Retrieve the current Google project ID
data "google_project" "project" {}

# Generate an SSH key pair for Linux instances.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: No 'comment' argument allowed here.
}

# Null resource to idempotently create the tenant-specific VPC network using gcloud.
# This prevents "resource already exists" errors on concurrent deployments.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to retrieve the details of the tenant VPC network.
# Depends on the null_resource to ensure the network exists before attempting to read it.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to idempotently create the shared internal firewall rule.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
}

# Null resource to idempotently create the shared IAP SSH firewall rule.
resource "null_resource" "allow_iap_ssh_provisioner" {
  count = var.os_type == "Linux" ? 1 : 0
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

  depends_on = [
    null_resource.vpc_provisioner # Ensure VPC exists
  ]
}

# Deploy the virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Using a default zone within the region
  # OMITTING 'project' here, relying on provider configuration or environment.

  # CRITICAL: Set deletion_protection to false as per instructions.
  deletion_protection = false

  # Boot disk configuration, using the specified custom image name.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network interface configuration.
  # CRITICAL: No 'access_config' block is present to avoid assigning a public IP,
  # relying on IAP for connectivity.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
  }

  # Service account with cloud-platform scopes for broader GCP service access.
  service_account {
    scopes = ["cloud-platform"]
  }

  # CRITICAL METADATA STRUCTURE: Combine metadata items.
  # startup-script for custom script and ssh-keys for SSH access.
  # metadata_startup_script can be a top-level attribute.
  metadata = {
    # SSH keys for Linux instances.
    # The 'packer' user is commonly used for key-based authentication.
    "ssh-keys" = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # Startup script passed as user data.
  metadata_startup_script = var.custom_script

  # Apply unique tags for per-instance firewall rules and IAP access.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]
}

# Per-instance firewall rule to allow public SSH access for Linux instances.
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

# Per-instance firewall rule to allow public RDP access for Windows instances.
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

# Per-instance firewall rule to allow public WinRM access for Windows instances.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # HTTP and HTTPS WinRM ports
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
}

# Output the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The Google Cloud instance ID of the deployed virtual machine."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the network tags applied to the instance.
output "network_tags" {
  description = "Network tags applied to the Google Compute Instance."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key.
# This output is marked as sensitive and will not be displayed in plain text by default.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (sensitive)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true
}