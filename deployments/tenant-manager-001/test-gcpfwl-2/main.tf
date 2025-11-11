# Required providers block
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Specify a compatible version
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # For generating SSH keys
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0" # For local-exec provisioner
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # For unique subnet IP ranges
    }
  }
}

# Google Cloud Platform Provider Configuration
provider "google" {
  project = var.project_id
  region  = var.region
}

# Terraform Variables Declaration
# CRITICAL: All variables must have a default value directly from the JSON.

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwl-2"
}

variable "region" {
  description = "GCP region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "os_type" {
  description = "Operating system type (e.g., Linux, Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "Custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "project_id" {
  description = "GCP Project ID."
  type        = string
  default     = "umos-ab24d"
}

# Resource to generate an SSH key pair for Linux instances
# FOR LINUX DEPLOYMENTS ONLY: Generate an SSH key pair
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0 # Only create if OS type is Linux
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
}

# CRITICAL NETWORKING: Get-or-Create Tenant VPC Network
# This null_resource uses gcloud CLI to ensure the tenant VPC exists idempotently.
# It first tries to describe the network; if it fails (exit code != 0), it creates it.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant VPC network details after it's provisioned.
# CRITICAL: depends_on ensures the network exists before Terraform tries to read it.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# CRITICAL NETWORKING: Get-or-Create Shared Firewall Rule for Internal Traffic
# This null_resource ensures a common firewall rule allowing internal traffic (10.0.0.0/8) exists.
resource "null_resource" "allow_internal_provisioner" {
  # Only run if the tenant_vpc data source has successfully resolved a name
  count = data.google_compute_network.tenant_vpc.name != null ? 1 : 0

  triggers = {
    tenant_vpc_name = data.google_compute_network.tenant_vpc.name
    project_id      = var.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
}

# CRITICAL NETWORKING: Get-or-Create Shared Firewall Rule for IAP SSH (Linux Only)
# This null_resource ensures the IAP SSH firewall rule exists for Linux instances.
resource "null_resource" "allow_iap_ssh_provisioner" {
  # Only run for Linux instances and if tenant_vpc data source has resolved a name
  count = var.os_type == "Linux" && data.google_compute_network.tenant_vpc.name != null ? 1 : 0

  triggers = {
    tenant_vpc_name = data.google_compute_network.tenant_vpc.name
    project_id      = var.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
}

# Resources to generate random integers for unique subnet IP CIDR ranges.
# CRITICAL: 'keepers' block ensures the numbers are unique for each instance deployment.
resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# CRITICAL NETWORKING: Create a new, unique subnetwork for this deployment.
resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link

  # Ensure subnet is created after the VPC is confirmed to exist
  depends_on = [
    null_resource.vpc_provisioner,
    random_integer.subnet_octet_2,
    random_integer.subnet_octet_3,
  ]
}

# CRITICAL: Create Per-Instance Firewall Rule for Public SSH (Linux Only)
# Allows inbound SSH from anywhere to this specific Linux instance via its unique tag.
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create for Linux instances

  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]
  description   = "Allow public SSH access to ${var.instance_name}"
  depends_on = [data.google_compute_network.tenant_vpc]
}

# CRITICAL: Create Per-Instance Firewall Rule for Public RDP (Windows Only)
# Allows inbound RDP from anywhere to this specific Windows instance via its unique tag.
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create for Windows instances

  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]
  description   = "Allow public RDP access to ${var.instance_name}"
  depends_on = [data.google_compute_network.tenant_vpc]
}

# CRITICAL: Create Per-Instance Firewall Rule for Public WinRM (Windows Only)
# Allows inbound WinRM from anywhere to this specific Windows instance via its unique tag.
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create for Windows instances

  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
  description   = "Allow public WinRM access to ${var.instance_name}"
  depends_on = [data.google_compute_network.tenant_vpc]
}


# Primary compute resource: Google Compute Instance
resource "google_compute_instance" "this_vm" {
  project        = var.project_id
  name           = var.instance_name
  machine_type   = var.vm_size
  zone           = "${var.region}-a" # Using a default zone within the specified region
  deletion_protection = false # CRITICAL: Required by instructions

  # Boot disk configuration
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION: Use the exact cloud image name provided.
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network interface configuration
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL STRUCTURE & PUBLIC IP: 'access_config {}' assigns an ephemeral public IP.
    access_config {
      // Ephemeral public IP is assigned here.
    }
  }

  # Service account for instance identity and permissions
  service_account {
    scopes = ["cloud-platform"] # Provides full access to all Cloud APIs
  }

  # CRITICAL METADATA STRUCTURE: All metadata must be placed inside a single 'metadata' map.
  # FORBIDDEN from using 'dynamic "metadata"' or 'metadata_startup_script'.
  metadata = {
    # USER DATA/CUSTOM SCRIPT: Pass custom_script to instance startup.
    "startup-script" = var.custom_script
    # FOR LINUX DEPLOYMENTS ONLY: Add SSH key to metadata for user 'packer'.
    # Uses the public key generated by tls_private_key.admin_ssh.
    "ssh-keys"       = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # CRITICAL: Tags applied to the instance for firewall rules and IAP.
  # Tags are conditional based on the OS type.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Explicit dependencies to ensure network infrastructure is ready before instance creation.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# Output Block for Private IP Address
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output Block for Public IP Address
output "public_ip" {
  description = "The public IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

# Output Block for Instance ID
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Output Block for Private SSH Key (sensitive)
# FOR LINUX DEPLOYMENTS ONLY: Exposes the generated private SSH key.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing Linux instances."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true # CRITICAL: Mark as sensitive to prevent exposure in logs.
}

# NEW OUTPUTS FOR NETWORKING: Exposes the network tags applied to the instance.
output "network_tags" {
  description = "Networking tags applied to the GCP instance."
  value       = google_compute_instance.this_vm.tags
}