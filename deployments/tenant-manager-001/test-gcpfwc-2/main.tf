# main.tf

# Required providers for Google Cloud Platform, TLS for SSH keys, and Random for unique subnet IPs, and Null for local-exec.
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

# Google Cloud Platform Provider Configuration
# CRITICAL: Project is intentionally omitted from the provider block,
# as the null_resource for get-or-create operations will specify it directly
# via 'gcloud' commands to ensure idempotency across multiple projects if needed.
provider "google" {
  region = var.region
}

# ----------------------------------------------------------------------------------------------------------------------
# GLOBAL VARIABLES
# These variables define the core configuration for the VM and its environment.
# Defaults are populated directly from the provided JSON configuration.
# ----------------------------------------------------------------------------------------------------------------------

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwc-2"
}

variable "region" {
  description = "GCP region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type/size for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for shared resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type (Linux or Windows) to determine specific configurations."
  type        = string
  default     = "Linux" # Derived from os.type in JSON
}

variable "custom_script" {
  description = "Custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# ----------------------------------------------------------------------------------------------------------------------
# DATA SOURCES
# Used to fetch existing resource information.
# ----------------------------------------------------------------------------------------------------------------------

# Data source to retrieve the current GCP project ID.
# This is crucial for dynamically constructing gcloud commands.
data "google_project" "project" {}

# Data source to retrieve the tenant-specific VPC network after it's provisioned.
# CRITICAL: This depends on the null_resource to ensure the network exists before attempting to read it.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# ----------------------------------------------------------------------------------------------------------------------
# TENANT VPC NETWORK AND SHARED FIREWALL RULES (Get-or-Create Idempotent Logic)
# These resources ensure that a shared tenant VPC and essential firewall rules are present.
# They use 'null_resource' with 'local-exec' to run gcloud commands for idempotent creation.
# ----------------------------------------------------------------------------------------------------------------------

# Null resource to provision the tenant-specific VPC network if it doesn't already exist.
# This uses 'gcloud compute networks describe' to check existence, and 'gcloud compute networks create' if it's not found.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    # CRITICAL: Using '>/dev/null 2>&1' to suppress output and rely solely on the command's exit code for '||' logic.
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Null resource to provision a shared firewall rule for internal network traffic.
# Allows all protocols from any IP within the 10.0.0.0/8 private range.
resource "null_resource" "allow_internal_provisioner" {
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating rules
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
}

# Null resource to provision a shared firewall rule for IAP SSH access.
# Allows TCP port 22 from the IAP IP range to instances tagged 'ssh-via-iap'.
resource "null_resource" "allow_iap_ssh_provisioner" {
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating rules
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
}

# ----------------------------------------------------------------------------------------------------------------------
# NETWORK CONFIGURATION
# Creates a unique subnet for this specific deployment within the tenant's VPC.
# ----------------------------------------------------------------------------------------------------------------------

# Resource to generate a random integer for creating a unique subnet IP range.
# This helps prevent IP range collisions in a multi-deployment scenario.
resource "random_integer" "subnet_octet" {
  min = 2  # Start from 2 to avoid reserving gateway or broadcast for simplicity
  max = 254
}

# Resource to create a new, unique subnetwork for the VM instance.
# This subnet is part of the shared tenant VPC but has its own dedicated IP range.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # Dynamically generated IP range
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link # Link to the tenant's VPC
  depends_on = [
    null_resource.vpc_provisioner # Ensure VPC exists before creating subnets
  ]
}

# ----------------------------------------------------------------------------------------------------------------------
# SSH KEY PAIR GENERATION (Linux Only)
# Generates an SSH key pair to be used for initial access to Linux VMs.
# ----------------------------------------------------------------------------------------------------------------------

# Resource to generate a private SSH key for Linux instances.
# CRITICAL: 'comment' argument is FORBIDDEN in 'tls_private_key'.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ----------------------------------------------------------------------------------------------------------------------
# VIRTUAL MACHINE DEPLOYMENT
# Deploys the Google Compute Engine virtual machine instance.
# ----------------------------------------------------------------------------------------------------------------------

# Primary resource for the Google Compute Engine virtual machine.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Deploying to zone 'a' within the specified region.

  # CRITICAL: OMITTING 'project' attribute from 'google_compute_instance' as per instructions.

  # CRITICAL: Disabling deletion protection as per instructions.
  deletion_protection = false

  # Boot disk configuration, including the specified custom image name.
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME: Using the exact image name provided in instructions.
      image = "ubuntu-22-04-19271224598"
    }
  }

  # CRITICAL STRUCTURE: Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link # Attach to the newly created subnet.

    # CRITICAL: This empty block assigns an ephemeral public IP address. DO NOT MOVE IT.
    access_config {
      # Ephemeral public IP is assigned by default when an empty access_config block is present.
    }
  }

  # CRITICAL STRUCTURE: Service account configuration.
  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"] # Grant full access to GCP services for the VM.
  }

  # Metadata for the instance, including SSH keys for Linux.
  metadata = {
    # CRITICAL: SSH keys for Linux instances.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # CRITICAL: Custom script for user data.
  # For GCP, 'metadata_startup_script' argument directly passes the script to the instance.
  metadata_startup_script = var.custom_script

  # Instance tags for applying firewall rules.
  # Conditional tags for Linux (IAP, instance-specific SSH) and Windows (instance-specific RDP/WinRM).
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  depends_on = [
    google_compute_subnetwork.this_subnet,      # Ensure subnet is ready
    null_resource.vpc_provisioner,              # Ensure VPC is ready
    null_resource.allow_internal_provisioner,   # Ensure shared internal firewall rule is ready
    null_resource.allow_iap_ssh_provisioner     # Ensure shared IAP SSH firewall rule is ready
  ]
}

# ----------------------------------------------------------------------------------------------------------------------
# PER-INSTANCE FIREWALL RULES
# Creates unique firewall rules to allow public SSH/RDP/WinRM access to THIS instance.
# ----------------------------------------------------------------------------------------------------------------------

# Firewall rule to allow public SSH access (TCP port 22) for Linux instances.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link # Associate with the tenant VPC
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]                       # Allow from all public IPs
  target_tags   = ["allow-ssh-${var.instance_name}"] # Apply to instances with this specific tag
  depends_on = [
    null_resource.vpc_provisioner,
    google_compute_instance.this_vm # Ensure VM exists before attaching rules
  ]
}

# Firewall rule to allow public RDP access (TCP port 3389) for Windows instances.
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
  depends_on = [
    null_resource.vpc_provisioner,
    google_compute_instance.this_vm
  ]
}

# Firewall rule to allow public WinRM access (TCP ports 5985-5986) for Windows instances.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # Both HTTP and HTTPS WinRM
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
  depends_on = [
    null_resource.vpc_provisioner,
    google_compute_instance.this_vm
  ]
}

# ----------------------------------------------------------------------------------------------------------------------
# OUTPUTS
# These outputs provide important information about the deployed resources.
# ----------------------------------------------------------------------------------------------------------------------

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID of the virtual machine."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "Network tags associated with the virtual machine."
  value       = google_compute_instance.this_vm.tags
}

# CRITICAL: This output exposes the generated private SSH key and is marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (if Linux)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true
}