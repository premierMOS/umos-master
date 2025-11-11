# --- Providers ---
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
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

# The Google provider configuration. Project attribute is intentionally omitted as per instructions.
provider "google" {
  region = var.region
}

# --- Variables ---

variable "instance_name" {
  type        = string
  default     = "test-gcpfwb-3"
  description = "Name for the virtual machine instance."
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
  description = "Unique identifier for the tenant, used in resource naming for shared infrastructure."
}

variable "os_type" {
  type        = string
  default     = "Linux" # Derived from os.type in the JSON configuration
  description = "Operating system type (e.g., Linux or Windows), used for conditional logic."
}

variable "custom_script" {
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to be executed on instance startup. Passed as metadata_startup_script."
}

# --- Shared Tenant Resources (Get-or-Create Idempotent Logic via null_resource) ---

# Data source to retrieve the current GCP project ID, required for gcloud commands.
data "google_project" "project" {}

# Provisioner to get-or-create the tenant-specific VPC network.
# This ensures the network exists before other resources try to use it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the tenant VPC network after ensuring it exists.
# An explicit dependency ensures the null_resource completes first.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Provisioner to get-or-create the shared internal traffic firewall rule for the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Ensure VPC exists
}

# Provisioner to get-or-create the shared IAP SSH firewall rule for the tenant VPC (Linux only).
resource "null_resource" "allow_iap_ssh_provisioner" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create if OS type is Linux
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc] # Ensure VPC exists
}

# --- Unique Subnet for this Deployment ---

# Generates a random integer for a unique subnet IP range's second octet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Creates a unique subnetwork for this specific virtual machine deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [data.google_compute_network.tenant_vpc] # Ensure VPC is ready
}

# --- SSH Key Pair Generation (for Linux) ---

# Generates a new SSH private key locally for Linux instances.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Virtual Machine Deployment ---

# The primary compute resource for the virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name                = var.instance_name
  machine_type        = var.vm_size
  zone                = "${var.region}-c" # Using a default zone within the specified region
  deletion_protection = false            # As per instruction

  # Metadata for SSH keys (Linux only).
  metadata = var.os_type == "Linux" ? {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  } : {} # Empty map if not Linux, as SSH keys are not applicable.

  # Startup script for instance initialization.
  # If custom_script is an empty string, GCP will ignore this attribute.
  metadata_startup_script = var.custom_script

  # Tags for conditional firewall rules and IAP access.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Boot disk configuration, using the critically specified custom image name.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Use the exact specified cloud image name
    }
  }

  # Network interface configuration, attached to the unique subnet.
  # Includes an empty access_config block to assign an ephemeral public IP, as per instructions.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      # This empty block assigns an ephemeral public IP. DO NOT MOVE IT.
    }
  }

  # Service account for the instance with cloud-platform scopes.
  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"]
  }

  # Explicit dependencies to ensure network infrastructure is ready before instance creation.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    # The IAP provisioner is conditional, so only depend on it if it might be created.
    # Terraforms handles conditional dependency correctly if the resource has count=0.
    null_resource.allow_iap_ssh_provisioner
  ]
}

# --- Per-Instance Firewall Rules ---

# Firewall rule to allow public SSH access to this specific instance (if Linux).
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create for Linux instances
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Allow SSH from anywhere
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public RDP access to this specific instance (if Windows).
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create for Windows instances
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"] # Allow RDP from anywhere
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public WinRM access to this specific instance (if Windows).
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create for Windows instances
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"] # Allow WinRM from anywhere
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Outputs ---

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID of the deployed virtual machine."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "Network tags associated with the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (sensitive)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}