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

# Configure the Google Cloud provider with the specified project and region
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Variables Block ---

variable "instance_name" {
  type        = string
  default     = "test-gcpfwj-1"
  description = "Name of the virtual machine instance."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region where resources will be deployed."
}

variable "vm_size" {
  type        = string
  default     = "e2-micro"
  description = "Machine type for the virtual machine."
}

variable "tenant_id" {
  type        = string
  default     = "tenant-manager-001"
  description = "Identifier for the tenant, used for naming shared resources like VPCs and firewalls."
}

variable "os_type" {
  type        = string
  default     = "Linux"
  description = "Operating system type (Linux or Windows), used for conditional logic."
}

variable "custom_script" {
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to run on instance startup, passed as metadata_startup_script."
}

variable "project_id" {
  type        = string
  default     = "umos-ab24d"
  description = "GCP Project ID where resources will be deployed."
}

# --- SSH Key Generation (Linux Only) ---

# Generate a new RSA private key for SSH access if the OS type is Linux
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- GCP Networking and Tenant Isolation ---

# Resource to ensure the tenant VPC network exists, using a get-or-create pattern.
# This makes the operation idempotent and avoids conflicts if run concurrently.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the provisioned Tenant VPC Network.
# Explicitly depends on the null_resource to ensure creation before reading.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# Resource to ensure the shared internal traffic firewall rule exists (get-or-create).
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id    = var.tenant_id
    project_id   = var.project_id
    network_name = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists first
}

# Resource to ensure the shared IAP SSH firewall rule exists (get-or-create).
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id    = var.tenant_id
    project_id   = var.project_id
    network_name = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists first
}

# Generate a random integer for a unique subnet IP range
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  keepers = {
    # This keeper ensures a new random number is generated if instance_name changes
    instance_name = var.instance_name
  }
}

# Create a unique subnet for this specific deployment within the tenant VPC
resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [null_resource.vpc_provisioner]
}

# --- Per-Instance Firewall Rules for Public Access ---

# Firewall rule to allow public SSH access specifically to this Linux instance
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0 # Only create for Linux VMs
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"] # Allow SSH from anywhere

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  depends_on = [null_resource.vpc_provisioner]
}

# Firewall rule to allow public RDP access specifically to this Windows instance
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0 # Only create for Windows VMs
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"] # Allow RDP from anywhere

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
  depends_on = [null_resource.vpc_provisioner]
}

# Firewall rule to allow public WinRM access specifically to this Windows instance
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0 # Only create for Windows VMs
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"] # Allow WinRM from anywhere

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }
  depends_on = [null_resource.vpc_provisioner]
}

# --- Virtual Machine Instance ---

# The primary virtual machine instance resource
resource "google_compute_instance" "this_vm" {
  project           = var.project_id
  name              = var.instance_name
  machine_type      = var.vm_size
  zone              = "${var.region}-c" # Deploying to zone 'c' within the specified region
  deletion_protection = false # Allows the instance to be deleted easily

  # Boot Disk Configuration
  boot_disk {
    initialize_params {
      # CRITICAL: Use the exact custom image name provided
      image = "ubuntu-22-04-19271224598"
      size  = 50  # Default disk size in GB
      type  = "pd-ssd" # Default disk type
    }
  }

  # Network Interface Configuration
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # An empty access_config block assigns an ephemeral public IP address
    access_config {
      // Ephemeral public IP is assigned here
    }
  }

  # Service Account for VM permissions
  service_account {
    # Scopes define what Google Cloud services the VM can access.
    # "cloud-platform" grants broad access; consider least privilege in production.
    scopes = ["cloud-platform"]
  }

  # Instance Tags for applying firewall rules
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for SSH keys (Linux only)
  # CRITICAL METADATA STRUCTURE: This combines SSH keys. Startup script is handled by metadata_startup_script.
  metadata = var.os_type == "Linux" ? {
    ssh-keys = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
  } : {}

  # Startup script (user data) for instance initialization
  metadata_startup_script = var.custom_script

  # Explicit dependencies to ensure networking resources are ready before the VM
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_iap_ssh_provisioner,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm,
  ]
}

# --- Outputs Block ---

# Output the private IP address of the virtual machine
output "private_ip" {
  description = "The private IP address of the created VM."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the public IP address of the virtual machine
output "public_ip" {
  description = "The public IP address of the created VM (if assigned)."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

# Output the cloud provider's native instance ID
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the network tags associated with the virtual machine
output "network_tags" {
  description = "The network tags associated with the VM, used for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key (sensitive, Linux only)
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance (Linux only)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not applicable for Windows VMs"
  sensitive   = true # Mark as sensitive to prevent being displayed in plain text in logs/CLI output
}