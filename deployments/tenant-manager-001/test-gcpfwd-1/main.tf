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

# The 'project' attribute is omitted from the provider block as per instructions.
# Terraform will use the project configured in the environment (e.g., via gcloud auth application-default login).
provider "google" {
  region = var.region
}

# Variable definitions for key configuration values, with default values from JSON.
# This ensures the script can be run without interactive prompts.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwd-1"
}

variable "region" {
  description = "The GCP region to deploy the VM."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the VM."
  type        = string
  default     = "e2-micro"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux" # From os.type in JSON
}

variable "tenant_id" {
  description = "The unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "os_image_name" {
  description = "The custom cloud image name to use for the VM."
  type        = string
  default     = "ubuntu-22-04-19271224598" # CRITICAL: Specific custom image name provided.
}

# Data source to retrieve the current GCP project ID.
data "google_project" "project" {}

# Generate an SSH key pair for Linux instances.
# The 'comment' argument is explicitly forbidden as per instructions.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

################################################################################
# GCP Tenant Isolation & Shared Networking Resources (Get-or-Create)
# These resources implement a "get-or-create" pattern using gcloud CLI to
# ensure idempotency for shared tenant-level network components.
################################################################################

# Null resource to get or create the tenant's shared VPC network.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || \
      gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'
    EOT
  }
}

# Data source to read the tenant VPC network, ensuring it exists after the provisioner.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to get or create the shared firewall rule for internal traffic.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || \
      gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8
    EOT
  }
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to get or create the shared firewall rule for IAP SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || \
      gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap
    EOT
  }
  depends_on = [null_resource.vpc_provisioner]
}

# Generates a random integer for a unique subnet IP range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a unique subnet for this specific deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [null_resource.vpc_provisioner] # Ensure VPC is provisioned
}

################################################################################
# GCP Virtual Machine Deployment
################################################################################

# Deploy the virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Using a default zone within the region
  deletion_protection = false # As per instruction

  # CRITICAL: The 'project' attribute is omitted as per instructions.
  # project      = data.google_project.project.project_id 

  boot_disk {
    initialize_params {
      image = var.os_image_name # Custom image name as specified
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # An empty access_config block assigns an ephemeral public IP address.
    # CRITICAL: Do not move this block.
    access_config {}
  }

  # Service account with cloud-platform scope for basic functionality.
  # CRITICAL: This block must not contain an access_config.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Conditional tags for public access and IAP based on OS type.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # User data (startup script) for the instance.
  metadata = {
    metadata_startup_script = var.custom_script
    # SSH keys for Linux instances.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }
}

################################################################################
# Per-Instance Public Access Firewall Rules
# These rules allow public access specifically to this instance based on its tags.
################################################################################

# Firewall rule to allow public SSH access to this Linux instance.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on    = [null_resource.vpc_provisioner]
}

# Firewall rule to allow public RDP access to this Windows instance.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on    = [null_resource.vpc_provisioner]
}

# Firewall rule to allow public WinRM access to this Windows instance.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on    = [null_resource.vpc_provisioner]
}

################################################################################
# Outputs
# Expose key information about the deployed virtual machine.
################################################################################

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags applied to the virtual machine."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true
}