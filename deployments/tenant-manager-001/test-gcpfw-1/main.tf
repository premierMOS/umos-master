# This Terraform configuration deploys a Google Cloud Platform virtual machine.
# It adheres to secure and private cloud best practices, leveraging Infrastructure as Code.

# --- Terraform Configuration Block ---
# Defines the minimum Terraform version and required providers.
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Specify a suitable version range for stability
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0" # Used for local-exec provisioners
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Used for generating SSH key pairs
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # Used for generating unique subnet IP ranges
    }
  }
}

# --- Google Cloud Platform Provider Configuration ---
# Configures the GCP provider. The 'project' attribute is intentionally omitted
# as per critical instructions for tenant isolation and is expected to be
# configured via environment variables (e.g., GOOGLE_PROJECT) or gcloud CLI default project.
provider "google" {
  region = var.region
}

# --- Variables Block ---
# CRITICAL INSTRUCTION: All key configuration values from the JSON are declared
# as variables with 'default' values set directly from the provided configuration.
# This prevents interactive prompts during 'terraform plan' or 'terraform apply'.

variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpfw-1"
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

variable "tenant_id" {
  description = "Unique identifier for the tenant, used in resource naming for isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating System type of the VM (e.g., Linux, Windows). Used for conditional logic."
  type        = string
  default     = "Linux" # Derived from JSON: os.type
}

variable "custom_script" {
  description = "Optional custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Data Sources ---

# CRITICAL INSTRUCTION: Add a 'data "google_project" "project" {}' data source to get the current project ID.
# This is required for all gcloud commands executed by null_resources.
data "google_project" "project" {}

# --- GCP Networking (Get-or-Create Pattern for Shared Tenant Resources) ---
# CRITICAL INSTRUCTION: Implement a "get-or-create" pattern for shared tenant resources
# (VPC Network and Firewall Rules) using 'null_resource' and gcloud CLI for idempotency.

# CRITICAL INSTRUCTION: Get-or-Create Tenant VPC Network.
# This null_resource first attempts to describe the VPC network; if it doesn't exist,
# it creates it. This makes the operation idempotent and handles concurrent deployments.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    # The '&>/dev/null' redirects stdout and stderr to null, so '||' relies purely on exit code.
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# CRITICAL INSTRUCTION: Use a data block to read the VPC's data after creation.
# The 'depends_on' ensures that the VPC provisioning is completed before attempting to read its data.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# CRITICAL INSTRUCTION: Get-or-Create Shared Firewall Rules.
# This null_resource provisions a shared firewall rule allowing all internal traffic within the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  # Ensure the VPC exists before attempting to create firewall rules for it.
  depends_on = [data.google_compute_network.tenant_vpc]
}

# This null_resource provisions a shared firewall rule for IAP SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Resource to generate a random integer, ensuring a unique third octet for the subnet CIDR.
resource "random_integer" "subnet_octet" {
  min = 2  # Avoid common network ranges
  max = 254
}

# CRITICAL INSTRUCTION: Create a NEW subnet for THIS deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # Dynamically generated unique IP range
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link

  # Ensure the VPC is provisioned before creating a subnet within it.
  depends_on = [null_resource.vpc_provisioner]
}

# --- SSH Key Pair Generation (FOR LINUX DEPLOYMENTS ONLY) ---
# CRITICAL INSTRUCTION: Generate an SSH key pair using a 'tls_private_key' resource named "admin_ssh".
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.

resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# --- Virtual Machine Deployment ---

# Primary compute resource, named "this_vm".
resource "google_compute_instance" "this_vm" {
  name                = var.instance_name
  machine_type        = var.vm_size
  zone                = "${var.region}-a" # Defaulting to zone 'a' within the specified region
  deletion_protection = false           # CRITICAL: As per instruction.

  # CRITICAL IMAGE NAME INSTRUCTION: Use the exact, complete cloud image name provided.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598"
    }
  }

  # CRITICAL GCP NETWORKING STRUCTURE: The 'network_interface' and 'service_account' blocks
  # have a very specific structure that MUST be followed.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL NETWORKING REQUIREMENT: Include an empty 'access_config {}' block to assign an ephemeral public IP.
    access_config {
      # This empty block assigns an ephemeral public IP. DO NOT MOVE IT.
    }
  }

  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"] # Grant broad access to GCP services for the VM.
  }

  # Instance tags are set conditionally based on OS type for per-instance firewall rules and IAP.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # User data / startup script configuration.
  # CRITICAL INSTRUCTION: For GCP 'google_compute_instance', use 'metadata_startup_script'.
  metadata = {
    metadata_startup_script = var.custom_script
    # For Linux deployments, add the public SSH key to instance metadata.
    ssh-keys                = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh.public_key_openssh}" : null
  }
}

# --- Per-Instance Firewall Rules (For Isolated Public Access) ---
# CRITICAL INSTRUCTION: Create new 'google_compute_firewall' resources for THIS deployment
# to provide isolated public access, activated conditionally by OS type.

# Public SSH Rule for Linux instances.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0 # Only create if OS is Linux
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Allow SSH from any public IP
  # Ensure VPC and instance exist before creating firewall rule.
  depends_on = [data.google_compute_network.tenant_vpc, google_compute_instance.this_vm]
}

# Public RDP Rule for Windows instances (not active for this Linux example, but conditionally defined).
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0 # Only create if OS is Windows
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"] # Allow RDP from any public IP
  depends_on = [data.google_compute_network.tenant_vpc, google_compute_instance.this_vm]
}

# Public WinRM Rule for Windows instances (not active for this Linux example, but conditionally defined).
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0 # Only create if OS is Windows
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # WinRM default ports
  }

  source_ranges = ["0.0.0.0/0"] # Allow WinRM from any public IP
  depends_on = [data.google_compute_network.tenant_vpc, google_compute_instance.this_vm]
}

# --- Outputs Block ---
# CRITICAL INSTRUCTION: Include specific output blocks as required for future management and information.

# Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

# NEW OUTPUT: Output the network tags associated with the instance.
output "network_tags" {
  description = "The network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

# CRITICAL INSTRUCTION: Output the generated private SSH key, marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key generated for administrative access. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # Mark as sensitive to prevent it from being displayed in plain text in logs.
}