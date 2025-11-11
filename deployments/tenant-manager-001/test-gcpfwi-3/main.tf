# Terraform Configuration
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Google Cloud Platform Provider Configuration
# CRITICAL: OMITTING the 'project' attribute here as per instructions for tenant isolation.
provider "google" {
  region = var.region
}

# --- Variables ---

# Name of the virtual machine instance.
variable "instance_name" {
  type        = string
  description = "Name of the virtual machine instance."
  default     = "test-gcpfwi-3"
}

# GCP region where resources will be deployed.
variable "region" {
  type        = string
  description = "GCP region where resources will be deployed."
  default     = "us-central1"
}

# GCP zone where the VM instance will be deployed. Must be within the specified region.
variable "zone" {
  type        = string
  description = "GCP zone where the VM instance will be deployed."
  default     = "us-central1-c" # Default to a common zone within us-central1
}

# Machine type for the virtual machine (e.g., e2-micro, n1-standard-1).
variable "vm_size" {
  type        = string
  description = "Machine type for the virtual machine."
  default     = "e2-micro"
}

# Unique identifier for the tenant, used in resource naming to ensure isolation.
variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant."
  default     = "tenant-manager-001"
}

# Operating system type of the VM (Linux or Windows).
variable "os_type" {
  type        = string
  description = "Operating system type of the VM (Linux or Windows)."
  default     = "Linux" # Derived from os.type in the provided JSON
}

# Custom script to run on instance startup (user data/metadata_startup_script).
variable "custom_script" {
  type        = string
  description = "Custom script to run on instance startup."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- GCP Tenant Isolation: Get-or-Create VPC Network and Shared Firewall Rules ---

# Data source to retrieve the current GCP project ID.
# This is required for all gcloud commands that interact with project-level resources.
data "google_project" "project" {}

# Null resource to provision the tenant VPC network using gcloud CLI.
# This implements a "get-or-create" pattern to ensure idempotency across deployments.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the tenant VPC network created by the null_resource.
# CRITICAL: 'depends_on' ensures this data source runs only after the network is guaranteed to exist.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to provision the shared 'allow-internal' firewall rule using gcloud CLI.
# This rule allows all internal traffic within the 10.0.0.0/8 range.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Null resource to provision the shared 'allow-iap-ssh' firewall rule using gcloud CLI.
# This rule allows SSH access via Google Cloud IAP to instances tagged 'ssh-via-iap'.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Unique Subnet for this Deployment ---

# Generates a random integer (between 2 and 254) for the second octet of the subnet's IP range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Creates a new, unique subnet for this specific deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [null_resource.vpc_provisioner] # Ensure VPC exists before creating the subnet
}

# --- SSH Key Pair Generation (for Linux deployments) ---

# Generates a new private and public SSH key pair specifically for this deployment.
# CRITICAL: The 'comment' argument is explicitly FORBIDDEN for this resource.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Virtual Machine Deployment ---

# Main compute resource for the virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = var.zone

  # CRITICAL: OMITTING the 'project' attribute from the instance block as per instructions.
  # CRITICAL: 'deletion_protection' must be explicitly set to 'false'.
  deletion_protection = false

  # Boot Disk Configuration
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME: Using the exact cloud image name provided in the instructions.
      image = "ubuntu-22-04-19271224598"
      size  = 20 # Default disk size in GB, can be parameterized if needed.
    }
  }

  # Network Interface Configuration
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: This empty 'access_config {}' block assigns an ephemeral public IP address.
    # It MUST be placed directly inside 'network_interface' and NOT moved.
    access_config {}
  }

  # Service Account for VM identity and API access scopes.
  # CRITICAL: This 'service_account' block MUST NOT contain an 'access_config'.
  service_account {
    scopes = ["cloud-platform"] # Grants broad access; refine with least privilege principle as needed.
  }

  # Metadata for instance configuration, including SSH keys and startup scripts.
  metadata = {
    # For Linux VMs, inject the generated public SSH key.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh.public_key_openssh}" : null
    # Pass the custom startup script.
    metadata_startup_script = var.custom_script
  }

  # Conditional network tags based on OS type for firewall rule targeting.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Explicit dependencies to ensure network resources are in place before the VM is created.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# --- Per-Instance Firewall Rules for Isolated Public Access ---

# Firewall rule to allow public SSH access to this specific instance (Linux only).
# Uses 'count' to create the resource only if 'os_type' is "Linux".
resource "google_compute_firewall" "allow_public_ssh" {
  count       = var.os_type == "Linux" ? 1 : 0
  name        = "pmos-instance-${var.instance_name}-allow-ssh"
  network     = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Allows SSH from anywhere globally
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public RDP access to this specific instance (Windows only).
# Uses 'count' to create the resource only if 'os_type' is "Windows".
resource "google_compute_firewall" "allow_public_rdp" {
  count       = var.os_type == "Windows" ? 1 : 0
  name        = "pmos-instance-${var.instance_name}-allow-rdp"
  network     = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"] # Allows RDP from anywhere globally
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public WinRM access to this specific instance (Windows only).
# Uses 'count' to create the resource only if 'os_type' is "Windows".
resource "google_compute_firewall" "allow_public_winrm" {
  count       = var.os_type == "Windows" ? 1 : 0
  name        = "pmos-instance-${var.instance_name}-allow-winrm"
  network     = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # Standard WinRM ports
  }

  source_ranges = ["0.0.0.0/0"] # Allows WinRM from anywhere globally
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# --- Outputs ---

# Exposes the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the GCP VM instance."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique instance ID of the GCP VM."
  value       = google_compute_instance.this_vm.instance_id
}

# Exposes the generated private SSH key (for Linux instances).
# CRITICAL: This output MUST be marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key PEM content generated for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}

# Exposes the network tags applied to the instance.
output "network_tags" {
  description = "The network tags associated with the GCP VM instance."
  value       = google_compute_instance.this_vm.tags
}