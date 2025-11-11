# This Terraform script deploys a virtual machine on Google Cloud Platform,
# following secure DevOps best practices for tenant isolation and automation.

# Define required providers and their versions.
# The 'google' provider manages GCP resources.
# The 'tls' provider generates SSH key pairs.
# The 'null' provider is used for local-exec provisioners for imperative tasks.
# The 'random' provider generates random values for unique resource naming.
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Specify a compatible version range
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Specify a compatible version range
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0" # Specify a compatible version range
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # Specify a compatible version range
    }
  }
}

# Configure the Google Cloud provider.
# The 'project' attribute is intentionally omitted as per critical instructions
# to ensure the current authenticated project is used, aiding tenant isolation.
provider "google" {
  region = var.region # Deploy resources in the specified region.
}

# ---------------------------------------------------------------------------------------------------------------------
# Input Variables
# These variables allow easy customization of the VM deployment without modifying the core script.
# Default values are sourced directly from the provided JSON configuration.
# ---------------------------------------------------------------------------------------------------------------------

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwc-3"
}

variable "region" {
  description = "The GCP region where the VM will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) of the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux" # From JSON: os.type
}

variable "custom_script" {
  description = "A custom script to be run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# ---------------------------------------------------------------------------------------------------------------------
# GCP Networking Setup: Get-or-Create Shared Tenant VPC and Firewall Rules
# This section ensures tenant-isolated networking resources exist or are created idempotently.
# It uses 'null_resource' with 'local-exec' to run gcloud commands.
# ---------------------------------------------------------------------------------------------------------------------

# Data source to retrieve information about the current Google Cloud project.
data "google_project" "project" {}

# Null resource to idempotently provision the tenant-specific VPC network.
# It first attempts to describe the network; if it doesn't exist, it creates it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant VPC network details.
# 'depends_on' ensures the VPC is provisioned before attempting to read its data.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to idempotently provision a shared firewall rule allowing internal traffic (10.0.0.0/8).
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Ensure VPC exists before creating rules
}

# Null resource to idempotently provision a shared firewall rule for IAP (Identity-Aware Proxy) SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Ensure VPC exists before creating rules
}

# Resource to generate a random integer for the subnet IP CIDR range, ensuring uniqueness.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Resource to create a unique subnetwork for this deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # Dynamic unique IP range
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [data.google_compute_network.tenant_vpc] # Ensure VPC is ready
}

# ---------------------------------------------------------------------------------------------------------------------
# SSH Key Pair Generation (for Linux deployments)
# ---------------------------------------------------------------------------------------------------------------------

# Generates an RSA private and public key pair for SSH access.
# The 'comment' argument is explicitly forbidden as per critical instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ---------------------------------------------------------------------------------------------------------------------
# Per-Instance Firewall Rules
# These rules provide controlled public access specific to this VM and its OS type.
# ---------------------------------------------------------------------------------------------------------------------

# Firewall rule to allow public SSH access (TCP port 22) to the instance if it's Linux.
# The 'count' meta-argument conditionally creates this resource.
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0

  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Allows access from any IP for this specific tag
  target_tags   = ["allow-ssh-${var.instance_name}"]
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public RDP access (TCP port 3389) to the instance if it's Windows.
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0

  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public WinRM access (TCP ports 5985-5986) to the instance if it's Windows.
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0

  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
  depends_on    = [data.google_compute_network.tenant_vpc]
}


# ---------------------------------------------------------------------------------------------------------------------
# Google Compute Engine Virtual Machine Instance
# This is the primary compute resource for the deployment.
# ---------------------------------------------------------------------------------------------------------------------

resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Assuming 'c' as a default zone within the specified region.

  # 'project' attribute is omitted as per critical instructions.
  deletion_protection = false # Set to false as per critical instructions.

  # Boot disk configuration.
  boot_disk {
    initialize_params {
      # CRITICAL: Use the exact custom image name provided.
      image = "ubuntu-22-04-19271224598"
      size  = 50 # Default disk size (in GB), adjust as needed.
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link # Connects to the uniquely created subnet.
    access_config {
      # This empty block is CRITICAL for assigning an ephemeral public IP address,
      # required for management agents or public access. DO NOT MOVE OR REMOVE.
    }
  }

  # Service account for instance identity and permissions.
  # This block MUST NOT contain an access_config.
  service_account {
    scopes = ["cloud-platform"] # Grants broad access to GCP APIs for management and services.
  }

  # Metadata for the instance, including SSH keys for Linux.
  metadata = var.os_type == "Linux" ? {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  } : {} # Empty map if not Linux

  # CRITICAL: Custom script is passed directly via 'metadata_startup_script' for GCP.
  metadata_startup_script = var.custom_script

  # Instance tags for applying firewall rules.
  # Conditional based on OS type to apply appropriate firewall tags.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Explicit dependencies to ensure all networking and firewall resources are in place
  # before attempting to create the VM.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm,
  ]
}

# ---------------------------------------------------------------------------------------------------------------------
# Outputs
# These outputs provide important information about the deployed virtual machine.
# ---------------------------------------------------------------------------------------------------------------------

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags applied to the instance for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The private SSH key for accessing the instance. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # Mark as sensitive to prevent display in plaintext in Terraform output.
}