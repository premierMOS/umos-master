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
# The project ID is omitted from the provider block to allow it to be determined implicitly or by other means,
# as required by the critical instructions for tenant isolation and "get-or-create" patterns.
provider "google" {
  region = var.region
  # project = var.project_id # OMITTED as per instructions
}

# --- Variables Declaration ---

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azurefwa-2"
}

variable "region" {
  description = "The GCP region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used in resource naming for isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "A custom script to execute on the instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Data Sources ---

# Data source to retrieve the current GCP project ID.
data "google_project" "project" {}

# Data source to retrieve the tenant VPC network, ensuring it exists after the null_resource.
data "google_compute_network" "tenant_vpc" {
  name    = "pmos-tenant-${var.tenant_id}-vpc"
  project = data.google_project.project.project_id

  # Ensure this data source depends on the VPC being provisioned.
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

# --- Resources for Tenant Isolation and Shared Infrastructure (Get-or-Create Pattern) ---

# Null resource to get or create the tenant VPC network using gcloud.
# This ensures idempotency and tenant isolation by checking for existence before creating.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Null resource to get or create the shared internal traffic firewall rule for the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before creating rules
  ]
}

# Null resource to get or create the shared IAP SSH firewall rule for the tenant VPC.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before creating rules
  ]
}

# Resource to generate a random integer for creating a unique subnet IP range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Resource to create a new, unique subnet for this specific deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  private_ip_google_access = true # Enable private Google access for services

  # Ensure subnet is created after the tenant VPC is guaranteed to exist
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

# --- SSH Key Generation (for Linux instances) ---

# Generates a new SSH private key locally for Linux instances.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
  # comment = "admin-ssh-key-for-${var.instance_name}" # CRITICAL: FORBIDDEN to include 'comment'
}

# --- Per-Instance Public Firewall Rules ---

# Firewall rule for public SSH access (TCP 22) for Linux instances.
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

  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before creating rules
  ]
}

# Firewall rule for public RDP access (TCP 3389) for Windows instances.
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

  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before creating rules
  ]
}

# Firewall rule for public WinRM access (TCP 5985-5986) for Windows instances.
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

  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before creating rules
  ]
}

# --- Virtual Machine Instance ---

# Main compute resource for the virtual machine.
resource "google_compute_instance" "this_vm" {
  name                = var.instance_name
  machine_type        = var.vm_size
  zone                = "${var.region}-a" # Defaulting to zone 'a' within the region
  deletion_protection = false             # As per critical instructions

  # The project attribute is omitted as per critical instructions.

  # Boot disk configuration.
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION: Use the exact specified cloud image name.
      image = "ubuntu-22-04-19271224598"
      size  = 50 # Default disk size
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL NETWORKING REQUIREMENT: Empty access_config block assigns an ephemeral public IP.
    access_config {
      # This empty block assigns an ephemeral public IP. DO NOT MOVE IT.
    }
  }

  # Service account configuration with appropriate scopes.
  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"] # Full access to all Google Cloud services (broad for example)
  }

  # Conditional tags for public access firewall rules and IAP SSH.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for SSH keys (Linux only) and startup script.
  metadata = {
    # FOR LINUX DEPLOYMENTS ONLY: Add generated SSH public key to instance metadata.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
    # Pass custom script as metadata_startup_script.
    metadata_startup_script = var.custom_script
  }
}

# --- Outputs ---

# Exposes the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the VM instance."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Exposes the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the VM instance."
  value       = google_compute_instance.this_vm.instance_id
}

# Exposes the network tags assigned to the VM instance.
output "network_tags" {
  description = "Network tags applied to the VM instance for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

# Exposes the generated private SSH key. Marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (Linux only)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true
}