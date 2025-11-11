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

# Configure the Google Cloud provider.
# OMITTING 'project' from provider block as per instructions.
provider "google" {
  region = var.region
}

#region Variables
################################################################################
# Terraform Variables
################################################################################

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwi-2"
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
  description = "Unique identifier for the tenant, used in resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type of the VM (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "Custom script to be executed on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "image_name" {
  description = "The exact name of the custom OS image to use for the VM."
  type        = string
  default     = "ubuntu-22-04-19271224598"
}

#endregion Variables

#region GCP Project Data Source
################################################################################
# Data Sources
################################################################################

# Retrieves information about the current Google Cloud project.
data "google_project" "project" {}

#endregion GCP Project Data Source

#region Networking Resources
################################################################################
# GCP Networking Configuration (Tenant Isolation and Get-or-Create)
################################################################################

# Resource to get-or-create the tenant-specific VPC network.
# Uses 'local-exec' provisioner to run gcloud commands.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the details of the tenant VPC network, ensuring it exists.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Resource to get-or-create the shared firewall rule for internal traffic.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
}

# Resource to get-or-create the shared firewall rule for IAP SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
}

# Generates a random integer for creating a unique subnet IP range.
# The 'keepers' block ensures a new number is generated if the instance name changes.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Creates a new unique subnetwork for this specific VM deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  description   = "Subnet for instance ${var.instance_name}"
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

#endregion Networking Resources

#region Security and Access
################################################################################
# SSH Key Pair Generation (for Linux VMs)
################################################################################

# Generates a new RSA private key for SSH access.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # 'comment' argument is forbidden per critical instructions.
}

#region Per-Instance Firewall Rules
################################################################################
# Per-Instance Firewall Rules for Isolated Public Access
################################################################################

# Firewall rule to allow public SSH access (TCP 22) for Linux instances.
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
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

# Firewall rule to allow public RDP access (TCP 3389) for Windows instances.
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
    null_resource.vpc_provisioner
  ]
}

# Firewall rule to allow public WinRM access (TCP 5985-5986) for Windows instances.
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
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

#endregion Per-Instance Firewall Rules

#region Virtual Machine Deployment
################################################################################
# Google Compute Instance
################################################################################

# Primary compute resource: Google Compute Engine Virtual Machine.
resource "google_compute_instance" "this_vm" {
  # OMITTING 'project' from resource block as per instructions.
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Deploying to default 'a' zone within the region
  deletion_protection = false # As per critical instructions

  # Boot disk configuration, using the specified custom image.
  boot_disk {
    initialize_params {
      image = var.image_name
    }
  }

  # Network interface configuration.
  # CRITICAL: NO 'access_config' block to avoid public IP address.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
  }

  # Service account configuration for instance permissions.
  # CRITICAL: This block MUST NOT contain an access_config.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Tags for the instance, used by firewall rules for filtering.
  # Conditional tags based on OS type.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for the instance, including startup script and SSH keys.
  # CRITICAL METADATA STRUCTURE: using separate top-level 'metadata_startup_script' and 'metadata' blocks.
  metadata_startup_script = var.custom_script

  # SSH keys for Linux instances.
  # This block is only applicable for Linux instances, but defining it conditionally within the metadata map itself.
  metadata = {
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh.public_key_openssh}" : null
  }
}

#endregion Virtual Machine Deployment

#region Outputs
################################################################################
# Outputs
################################################################################

# Exposes the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Exposes the network tags applied to the instance.
output "network_tags" {
  description = "The network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

# Exposes the generated private SSH key, marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}

#endregion Outputs