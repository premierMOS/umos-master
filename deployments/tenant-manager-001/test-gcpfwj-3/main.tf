# --- Providers Configuration ---
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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Configure the Google Cloud provider with the specified project and region.
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Variables Declaration ---
# CRITICAL: All variables must have a 'default' value from the JSON to prevent interactive prompts.

variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpfwj-3"
}

variable "region" {
  description = "Google Cloud region where the resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "Optional custom script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "os_type" {
  description = "Operating system type (Linux or Windows)."
  type        = string
  default     = "Linux" # Derived from os.type in JSON
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used in naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
  default     = "umos-ab24d" # Derived from gcpDefaultProjectId in JSON
}

# --- SSH Key Pair Generation (for Linux Deployments) ---
# Generate a new SSH private key to be used for instance access if OS type is Linux.
resource "tls_private_key" "admin_ssh" {
  # CRITICAL: The 'comment' argument is forbidden as it's not supported by tls_private_key.
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- GCP Tenant Networking and Firewall Configuration (Get-or-Create Idempotent Pattern) ---

# CRITICAL: Use null_resource with local-exec to implement get-or-create for shared VPC.
# This ensures the VPC exists without Terraform directly managing its lifecycle, preventing
# "resource already exists" errors on concurrent deployments if the VPC is a shared tenant resource.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
  }

  provisioner "local-exec" {
    # Check if VPC exists; if not, create it. '>/dev/null 2>&1' suppresses output.
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
    interpreter = ["bash", "-c"]
  }
}

# Data source to read the shared tenant VPC network's details.
# CRITICAL: 'depends_on' ensures this data block runs only after the VPC is guaranteed to exist.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# CRITICAL: Get-or-create for a shared firewall rule allowing internal (10.0.0.0/8) traffic.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
    vpc_name   = data.google_compute_network.tenant_vpc.name # Trigger re-run if VPC name changes (though it shouldn't)
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
    interpreter = ["bash", "-c"]
    # Explicit dependency to ensure the data source is resolved before executing the command.
    environment = {
      DUMMY_VAR = data.google_compute_network.tenant_vpc.name
    }
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# CRITICAL: Get-or-create for a shared firewall rule allowing IAP (Identity-Aware Proxy) SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
    vpc_name   = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
    interpreter = ["bash", "-c"]
    environment = {
      DUMMY_VAR = data.google_compute_network.tenant_vpc.name
    }
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# CRITICAL: Random integer to generate a unique subnet IP range for this deployment
# to avoid collisions when multiple instances are deployed concurrently.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  # CRITICAL: 'keepers' ensure a new random value is generated only if the instance_name changes,
  # maintaining idempotency for the subnet's IP range.
  keepers = {
    instance_name = var.instance_name
  }
}

# CRITICAL: Create a unique subnet for this specific VM deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  project       = var.project_id
  # Explicit dependency to ensure the VPC is ready.
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# CRITICAL: Per-instance firewall rule to allow public SSH access for Linux instances.
resource "google_compute_firewall" "allow_public_ssh" {
  # This rule is only created if the OS type is Linux.
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  project = var.project_id
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  # The target tag is specific to this instance for granular control.
  target_tags   = ["allow-ssh-${var.instance_name}"]
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# CRITICAL: Per-instance firewall rule to allow public RDP access for Windows instances.
resource "google_compute_firewall" "allow_public_rdp" {
  # This rule is only created if the OS type is Windows.
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  project = var.project_id
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  # The target tag is specific to this instance for granular control.
  target_tags   = ["allow-rdp-${var.instance_name}"]
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# CRITICAL: Per-instance firewall rule to allow public WinRM access for Windows instances.
resource "google_compute_firewall" "allow_public_winrm" {
  # This rule is only created if the OS type is Windows.
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  project = var.project_id
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  # The target tag is specific to this instance for granular control.
  target_tags   = ["allow-winrm-${var.instance_name}"]
  depends_on    = [data.google_compute_network.tenant_vpc]
}

# --- Virtual Machine Instance Deployment ---
resource "google_compute_instance" "this_vm" {
  # CRITICAL: Name the primary compute resource "this_vm".
  name         = var.instance_name
  project      = var.project_id
  machine_type = var.vm_size
  # Deploying to a specific zone within the region (e.g., us-central1-a).
  zone         = "${var.region}-a"
  # CRITICAL: Explicitly set deletion protection to false.
  deletion_protection = false

  # Boot disk configuration, using the exact custom image name as specified.
  boot_disk {
    initialize_params {
      # CRITICAL: Exact image name provided in the instructions.
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network interface configuration.
  network_interface {
    # Instance is deployed into the unique subnet created for this deployment.
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: `access_config {}` block assigns an ephemeral public IP address.
    access_config {
      # This block can be empty; its mere presence enables public IP.
    }
  }

  # CRITICAL: Service account for instance's default scopes.
  service_account {
    # Grants the VM instance broad access to Google Cloud resources.
    scopes = ["cloud-platform"]
  }

  # CRITICAL: Tags for firewall rules, conditional based on OS type.
  # "ssh-via-iap" is for the shared IAP firewall rule for Linux.
  # The other tags are for instance-specific public access firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # CRITICAL: Metadata for SSH keys (Linux) and startup script.
  # 'metadata' map for other key-value pairs, like SSH keys for Linux.
  # 'metadata_startup_script' is a separate top-level attribute for user data.
  metadata = {
    # CRITICAL: SSH Key for Linux deployments only.
    # The 'tls_private_key.admin_ssh.public_key_openssh' provides the public key.
    # The format 'username:public_key' is required for Google Cloud.
    # Set to null if OS type is not Linux to avoid adding unnecessary metadata.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh.public_key_openssh}" : null
  }

  # CRITICAL: User data/Custom script for GCP instances.
  # The content of 'custom_script' variable is passed as a startup script.
  metadata_startup_script = var.custom_script

  # Explicit dependencies to ensure networking resources are in place before the VM.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
    google_compute_firewall.allow_public_ssh, # Will be skipped if count is 0 for Windows
    google_compute_firewall.allow_public_rdp, # Will be skipped if count is 0 for Linux
    google_compute_firewall.allow_public_winrm, # Will be skipped if count is 0 for Linux
  ]
}

# --- Outputs ---
# CRITICAL: Expose the private IP address of the virtual machine.
output "private_ip" {
  description = "The internal IP address of the VM instance."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# CRITICAL: Expose the public IP address of the virtual machine.
output "public_ip" {
  description = "The public IP address of the VM instance."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

# CRITICAL: Expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the VM instance in GCP."
  value       = google_compute_instance.this_vm.instance_id
}

# CRITICAL: Expose network tags for the instance.
output "network_tags" {
  description = "The network tags applied to the instance."
  value       = google_compute_instance.this_vm.tags
}

# CRITICAL: Expose the generated private SSH key.
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance (SENSITIVE)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}