# Required providers for Google Cloud Platform, TLS key generation, and random integer generation.
terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "~> 5.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Google Cloud provider configuration.
# The 'project' attribute is intentionally omitted here as per critical instructions.
provider "google" {
  region = var.region
}

# --- Variables Block ---
# Declaring Terraform variables for key configuration values with default values from the JSON.
variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpfwi-1"
}

variable "region" {
  description = "Google Cloud region where the VM will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Identifier for the tenant, used in naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type (e.g., Linux, Windows)."
  type        = string
  default     = "Linux" # From os.type in JSON configuration
}

variable "custom_script" {
  description = "Optional custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Shared Tenant Resources (Get-or-Create Idempotent Logic) ---

# Data source to retrieve the current Google project ID.
data "google_project" "project" {}

# Null resource to idempotently provision the tenant VPC network using gcloud CLI.
# This ensures the network exists without causing "resource already exists" errors.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the provisioned tenant VPC network's data.
# Depends on the null_resource to ensure the network is created before being read.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to idempotently provision the shared internal firewall rule.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating rules
}

# Null resource to idempotently provision the shared IAP SSH firewall rule.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating rules
}

# --- Unique Subnet for This Deployment ---

# Generates a random integer for a unique third octet in the subnet IP range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Creates a new subnetwork for this specific deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [null_resource.vpc_provisioner]
}

# --- SSH Key Pair Generation (for Linux VMs only) ---
# Generates a new TLS private key for SSH access.
# This resource is conditionally created based on the 'os_type' variable.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
  # The 'comment' argument is forbidden and intentionally omitted.
}

# --- Virtual Machine Deployment ---

# The primary compute resource for the virtual machine.
resource "google_compute_instance" "this_vm" {
  name                 = var.instance_name
  machine_type         = var.vm_size
  zone                 = "${var.region}-c" # Assuming 'c' as a default zone in the specified region.
  deletion_protection  = false              # As per critical instructions.

  # Boot disk configuration, using the custom image name.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Exact image name provided.
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # An empty access_config block assigns an ephemeral public IP address.
    # This is critical for connectivity for management agents like AWS SSM.
    access_config {}
  }

  # Service account configuration with appropriate scopes.
  service_account {
    scopes = ["cloud-platform"]
  }

  # User data for instance startup script, for example, to install software or configure settings.
  metadata_startup_script = var.custom_script

  # Tags for network firewall rules, conditional based on OS type.
  # These tags allow specific inbound traffic based on the OS.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # SSH keys metadata for Linux instances, formatted for GCP.
  # This provides the public key to the VM for user 'packer'.
  metadata = var.os_type == "Linux" ? {
    ssh-keys = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
  } : {}

  # Ensure the instance waits for the subnet to be created.
  depends_on = [google_compute_subnetwork.this_subnet]
}

# --- Per-Instance Firewall Rules ---

# Firewall rule to allow public SSH access for Linux instances.
# Conditionally created only if 'os_type' is "Linux".
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
  depends_on    = [null_resource.allow_iap_ssh_provisioner] # Ensure shared rules are processed first.
}

# Firewall rule to allow public RDP access for Windows instances.
# Conditionally created only if 'os_type' is "Windows".
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
  depends_on    = [null_resource.allow_iap_ssh_provisioner] # Ensure shared rules are processed first.
}

# Firewall rule to allow public WinRM access for Windows instances.
# Conditionally created only if 'os_type' is "Windows".
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
  depends_on    = [null_resource.allow_iap_ssh_provisioner] # Ensure shared rules are processed first.
}

# --- Outputs ---

# Exposes the private IP address of the virtual machine for internal network access.
output "private_ip" {
  description = "The private IP address of the created VM."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Exposes the cloud provider's native instance ID for management and reference.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

# Exposes the network tags applied to the instance, useful for understanding firewall rules.
output "network_tags" {
  description = "The network tags applied to the VM for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

# Exposes the generated private SSH key for Linux instances.
# This output is marked as sensitive to prevent it from being displayed in plaintext in logs.
output "private_ssh_key" {
  description = "The generated private SSH key for connecting to the Linux VM."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux VM, no SSH key generated."
  sensitive   = true
}