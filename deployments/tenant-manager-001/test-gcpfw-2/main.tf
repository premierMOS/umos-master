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

# Configure the Google Cloud provider
provider "google" {
  # The 'project' attribute is omitted as per critical instructions.
  region = var.region
}

# --- Variables Block ---
# All key configuration values are declared as variables with default values
# pulled directly from the provided JSON configuration.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfw-2"
}

variable "region" {
  description = "The GCP region to deploy resources in."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "A custom startup script to run on the VM."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "The unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

# --- Data Sources ---

# Get the current Google Cloud project ID.
data "google_project" "project" {}

# --- Tenant-Specific VPC Network (Get-or-Create) ---

# This null_resource ensures that the tenant-specific VPC network exists.
# It uses 'gcloud' to first describe the network; if it doesn't exist, it creates it.
# The '&>/dev/null' suppresses output and ensures the '||' condition works based on exit codes.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
  }

  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to retrieve the details of the tenant VPC network.
# It explicitly depends on the 'vpc_provisioner' to ensure the network is created before being read.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = data.google_project.project.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# --- Shared Firewall Rules (Get-or-Create) ---

# Ensures a firewall rule allowing internal traffic (10.0.0.0/8) exists within the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_vpc_name = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Ensures a firewall rule allowing SSH access via IAP (Identity-Aware Proxy) exists for the tenant VPC.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_vpc_name = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Unique Subnet Creation ---

# Generate a random integer to create a unique third octet for the subnet's IP range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a new, unique subnetwork for this specific deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  # Ensure the VPC is provisioned and available before creating the subnet.
  depends_on    = [null_resource.vpc_provisioner]
}

# --- SSH Key Pair Generation (Linux Only) ---

# Generate an RSA private key for SSH access if the OS type is Linux.
# CRITICAL: The 'comment' argument is explicitly forbidden for 'tls_private_key'.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Virtual Machine Deployment ---

# Deploy the primary virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  # GCP instances require a zone; using '-a' as a common default for the specified region.
  zone         = "${var.region}-a"

  # As per instructions, 'project' attribute is omitted from provider and resource.
  deletion_protection = false

  boot_disk {
    initialize_params {
      # CRITICAL: Use the exact cloud image name provided.
      image = "ubuntu-22-04-19271224598"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: This empty block assigns an ephemeral public IP address. DO NOT MOVE IT.
    access_config {
    }
  }

  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"]
  }

  # Pass the custom script to the instance's startup metadata.
  metadata_startup_script = var.custom_script

  # Apply network tags conditionally based on OS type for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Add SSH public key to instance metadata for Linux instances.
  metadata = var.os_type == "Linux" ? {
    ssh-keys = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
  } : {}

  # Explicit dependencies to ensure networking setup is complete before instance creation.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
    # Ensure TLS key is generated before instance metadata relies on it
    tls_private_key.admin_ssh
  ]
}

# --- Per-Instance Firewall Rules ---

# Firewall rule to allow public SSH access (TCP 22) for Linux instances.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
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

# Firewall rule to allow public RDP access (TCP 3389) for Windows instances.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
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

# Firewall rule to allow public WinRM access (TCP 5985-5986) for Windows instances.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
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

# --- Outputs Block ---

# Exposes the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Exposes the network tags applied to the virtual machine.
output "network_tags" {
  description = "Network tags applied to the instance."
  value       = google_compute_instance.this_vm.tags
}

# Exposes the generated private SSH key for Linux instances.
# This output is marked as sensitive to prevent it from being displayed in plain text in logs.
output "private_ssh_key" {
  description = "The generated private SSH key for Linux instances."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true
}