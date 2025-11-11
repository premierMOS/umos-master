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

# --- Provider Configuration ---
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Input Variables ---

# The name of the virtual machine instance.
variable "instance_name" {
  type        = string
  description = "Name of the VM instance."
  default     = "test-gcpfwk-3"
}

# The GCP region where resources will be deployed.
variable "region" {
  type        = string
  description = "The GCP region to deploy resources in."
  default     = "us-central1"
}

# The machine type (VM size) for the instance.
variable "vm_size" {
  type        = string
  description = "The machine type for the VM (e.g., e2-micro, n1-standard-1)."
  default     = "e2-micro"
}

# Unique identifier for the tenant. Used for resource naming.
variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant."
  default     = "tenant-manager-001"
}

# The operating system type (Linux or Windows). Used for conditional resource deployment.
variable "os_type" {
  type        = string
  description = "The operating system type (Linux or Windows)."
  default     = "Linux"
}

# Custom script to run on instance startup.
variable "custom_script" {
  type        = string
  description = "Custom script to execute on VM startup."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# The default GCP project ID for resource deployment.
variable "project_id" {
  type        = string
  description = "The default GCP project ID."
  default     = "umos-ab24d"
}

# The exact custom image name to be used for the VM.
variable "image_name" {
  type        = string
  description = "The custom image name for the VM boot disk."
  default     = "ubuntu-22-04-19271224598"
}

# --- SSH Key Pair Generation (for Linux VMs) ---
# Generates a new SSH private and public key pair.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

# --- Get-or-Create Tenant VPC Network ---
# Uses local-exec to ensure the tenant-specific VPC network exists.
# This prevents "resource already exists" errors and ensures idempotency.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = var.project_id
  }

  provisioner "local-exec" {
    # Check if VPC exists, if not, create it.
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant's VPC network details after it's provisioned.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is provisioned before reading.
}

# --- Get-or-Create Shared Firewall Rules for Tenant VPC ---

# Ensures a firewall rule allowing internal traffic (10.0.0.0/8) within the tenant VPC exists.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = var.project_id
    vpc_name  = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    # Check if firewall rule exists, if not, create it.
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Ensures a firewall rule allowing SSH access via IAP for Linux VMs exists.
resource "null_resource" "allow_iap_ssh_provisioner" {
  count = var.os_type == "Linux" ? 1 : 0 # Only provision if OS is Linux
  
  triggers = {
    tenant_id = var.tenant_id
    project_id = var.project_id
    vpc_name  = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    # Check if firewall rule exists, if not, create it.
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Unique Subnet Creation ---

# Generates a random second octet for the subnet IP range to ensure uniqueness.
resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Generates a random third octet for the subnet IP range to ensure uniqueness.
resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Creates a unique subnetwork for this specific VM deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link

  depends_on = [
    random_integer.subnet_octet_2,
    random_integer.subnet_octet_3,
    data.google_compute_network.tenant_vpc
  ]
}

# --- Per-Instance Firewall Rules for Public Access ---

# Firewall rule to allow public SSH access for this specific Linux instance.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public RDP access for this specific Windows instance.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public WinRM access for this specific Windows instance.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Virtual Machine Deployment ---

# Deploys the Google Compute Engine virtual machine instance.
resource "google_compute_instance" "this_vm" {
  project          = var.project_id
  name             = var.instance_name
  machine_type     = var.vm_size
  zone             = "${var.region}-a" # Defaulting to zone 'a' within the region
  deletion_protection = false

  # Define the boot disk using the custom image.
  boot_disk {
    initialize_params {
      image = var.image_name
    }
  }

  # Configure the network interface.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # Assigns an ephemeral public IP address for direct connectivity.
    access_config {
      // Ephemeral public IP is assigned here.
    }
  }

  # Service account with Cloud Platform scopes for agent communication (e.g., SSM).
  service_account {
    scopes = ["cloud-platform"]
  }

  # Metadata for SSH keys (for Linux) and startup script.
  metadata_startup_script = var.custom_script

  metadata = {
    # SSH key for Linux instances, formatted for GCP's metadata.
    # The 'packer' username is often used for automated image builds, and works generally.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # Apply network tags based on OS type for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

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

# Exposes the private IP address of the deployed VM.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Exposes the public IP address of the deployed VM.
output "public_ip" {
  description = "The public IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Exposes the network tags applied to the instance.
output "network_tags" {
  description = "The network tags applied to the instance, used by firewall rules."
  value       = google_compute_instance.this_vm.tags
}

# Exposes the generated private SSH key for Linux VMs. Marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key generated for the Linux VM. Store securely!"
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Windows VM"
  sensitive   = true
}