# This Terraform script deploys a virtual machine on Google Cloud Platform
# according to the provided JSON configuration.

# --- Providers ---
# Configure the Google Cloud provider. The project ID is typically
# inherited from the environment (e.g., `gcloud auth application-default login`)
# as per critical instructions to omit it from the provider block.
provider "google" {
  region = var.region
}

# Required for generating SSH key pairs.
provider "tls" {}

# Required for generating unique random integers for subnet CIDR blocks.
provider "random" {}

# Required for the 'local-exec' provisioner to run gcloud commands.
provider "null" {}

# --- Variables ---
# General platform information
variable "platform_name" {
  description = "The name of the cloud platform."
  type        = string
  default     = "Google Cloud Platform"
}

variable "platform_os_image_id" {
  description = "The OS image ID provided in the platform details (might differ from actual image name used)."
  type        = string
  default     = "ubuntu-22.04-gcp-1762876673554"
}

variable "platform_platform" {
  description = "The platform type (e.g., GCP, AWS)."
  type        = string
  default     = "GCP"
}

# VM instance configuration
variable "instance_name" {
  description = "The desired name for the virtual machine instance."
  type        = string
  default     = "test-gcpfwh-1"
}

variable "region" {
  description = "The GCP region where the VM will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "A custom script to execute on the VM instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# OS details
variable "os_name" {
  description = "The friendly name of the operating system image."
  type        = string
  default     = "ubuntu-22-04-gcp-19271224598" # Note: This is overridden by the critical instruction's explicit image name.
}

variable "os_version" {
  description = "The version of the operating system."
  type        = string
  default     = "Custom Build"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

# Tenant information for shared resources
variable "tenant_id" {
  description = "Unique identifier for the tenant, used in naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

# --- Data Sources ---
# Get the current Google Cloud Project ID. Required for gcloud commands.
data "google_project" "project" {}

# --- SSH Key Pair Generation (for Linux VMs) ---
# Generate a new TLS private key for SSH access if the OS type is Linux.
resource "tls_private_key" "admin_ssh" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create if OS type is Linux
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: 'comment' argument is forbidden by instructions.
}

# --- Tenant Networking (Get-or-Create Idempotent Logic via null_resource) ---

# Provisioner to get or create the shared tenant VPC network.
# This ensures the network exists without failing if it's already there.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = data.google_project.project.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the details of the tenant VPC network.
# This depends on the null_resource to ensure the network is created/exists before reading.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Provisioner to get or create the shared firewall rule for internal traffic (10.0.0.0/8).
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = data.google_project.project.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists
}

# Provisioner to get or create the shared firewall rule for IAP SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = data.google_project.project.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists
}

# --- Unique Subnet for this Deployment ---

# Generate a random integer for a unique subnet IP range to avoid collisions.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Create a unique subnetwork for this specific VM deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  # Ensure the subnet is created after the VPC is confirmed to exist.
  depends_on = [null_resource.vpc_provisioner]
}

# --- Per-Instance Firewall Rules (for public access, conditional) ---

# Allow public SSH access for Linux VMs based on a unique tag.
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
  depends_on = [null_resource.vpc_provisioner]
}

# Allow public RDP access for Windows VMs based on a unique tag.
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
  depends_on = [null_resource.vpc_provisioner]
}

# Allow public WinRM access for Windows VMs based on a unique tag.
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
  depends_on = [null_resource.vpc_provisioner]
}

# --- Virtual Machine Resource ---
# Deploy the primary virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Using zone 'c' as a default suffix for the region.
  deletion_protection = false # As per instruction.

  # CRITICAL IMAGE NAME INSTRUCTION: Use the exact specified image name.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: No 'access_config' block to avoid assigning a public IP,
    # connectivity is via IAP.
  }

  # Service account with cloud-platform scope.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Conditional tags for the instance, used by per-instance firewall rules and IAP.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Custom script (user data) for instance initialization.
  # For GCP, this is passed via 'metadata_startup_script'.
  metadata = merge(
    var.custom_script != "" ? { metadata_startup_script = var.custom_script } : {},
    var.os_type == "Linux" ? { "ssh-keys" = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" } : {}
  )

  # Ensure the VPC and subnet are ready before creating the instance.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner
  ]
}

# --- Outputs ---
# Expose the private IP address of the created VM.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

# Expose the network tags applied to the instance.
output "network_tags" {
  description = "The list of network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

# Expose the generated private SSH key (sensitive).
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (if Linux)."
  value     = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A (Windows VM)"
  sensitive = true
}