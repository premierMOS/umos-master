# This Terraform HCL script deploys a Google Cloud Platform (GCP) virtual machine
# based on the provided JSON configuration. It adheres to critical instructions
# for variable declaration, resource naming, networking, SSH key management,
# and idempotent tenant-level resource provisioning.

# Terraform configuration block
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Recommended to specify a compatible version
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Recommended to specify a compatible version
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # Recommended to specify a compatible version
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0" # Recommended to specify a compatible version
    }
  }
}

# Google Cloud Platform provider configuration
# CRITICAL: The 'project' attribute is intentionally omitted here and from resources.
# Terraform will infer the project from the gcloud CLI configuration or environment variables.
provider "google" {
  region = var.region
}

# --- Variable Declarations with Default Values ---
# All default values are sourced directly from the provided JSON configuration.

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwi-3"
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
  description = "Unique identifier for the tenant, used in naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type (Linux or Windows), used for conditional logic."
  type        = string
  default     = "Linux" # Sourced from os.type in JSON
}

variable "custom_script" {
  description = "Custom script to execute on instance startup (user data/metadata startup script)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- GCP Tenant-level Networking (Idempotent Get-or-Create Pattern) ---

# Data source to retrieve the current GCP project ID.
# This is crucial for correctly scoping gcloud CLI commands.
data "google_project" "project" {}

# Null resource to idempotently provision the tenant VPC network using gcloud CLI.
# This ensures the VPC exists (or is created) before any dependent Terraform resources are deployed.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the configuration of the tenant VPC network.
# CRITICAL: The 'depends_on' ensures this data source executes only after the VPC is guaranteed to exist.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to idempotently provision a shared firewall rule for internal traffic.
# This rule allows all traffic within the 10.0.0.0/8 private IP range.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Null resource to idempotently provision a shared firewall rule for IAP SSH access.
# This enables secure SSH access via Google's Identity-Aware Proxy.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Unique Subnet for this Deployment ---

# Random integer resource to generate a unique third octet for the subnet's CIDR range.
# This helps prevent IP CIDR collisions during concurrent deployments.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  # The 'keepers' block ensures that a new random number is generated only if
  # the 'instance_name' variable changes, maintaining uniqueness for each deployment.
  keepers = {
    instance_name = var.instance_name
  }
}

# Google Compute Subnetwork resource for this specific deployment.
# It uses the tenant VPC and a dynamically generated unique IP CIDR range.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  # Explicit dependencies to ensure proper provisioning order.
  depends_on    = [
    null_resource.vpc_provisioner,
    random_integer.subnet_octet,
  ]
}

# --- SSH Key Pair Generation (for Linux instances) ---

# CRITICAL: For Linux deployments, generate a new TLS private key for SSH access.
# This resource MUST NOT contain a 'comment' argument as per instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Virtual Machine Deployment ---

# The primary compute resource for the virtual machine.
# CRITICAL: Named "this_vm" as per instructions.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  # Defaulting to zone 'a' within the specified region for simplicity.
  # In production, consider a more robust zone selection strategy.
  zone         = "${var.region}-a"
  # CRITICAL: Deletion protection set to false as per instruction.
  deletion_protection = false

  # Boot disk configuration.
  boot_disk {
    initialize_params {
      # CRITICAL: Use the exact, complete custom image name provided.
      image = "ubuntu-22-04-19271224598"
      size  = 50 # Default disk size in GB
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: The 'access_config' block is intentionally omitted here.
    # This prevents the instance from being assigned a public IP address,
    # relying on IAP for secure remote access.
  }

  # Service account for instance identity and permissions.
  # This grants the VM permissions to interact with other GCP services.
  service_account {
    scopes = ["cloud-platform"] # Grants broad access; refine for least privilege in production.
    # CRITICAL: This block MUST NOT contain an 'access_config' block.
  }

  # Conditional tags applied to the instance for firewall rules and IAP access.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # CRITICAL METADATA STRUCTURE: Combined metadata for SSH key and startup script.
  # The 'ssh-keys' entry is for OS login via SSH.
  metadata = {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # CRITICAL: 'metadata_startup_script' is used directly for the custom script.
  metadata_startup_script = var.custom_script

  # Explicit dependencies to ensure tenant-level network resources are in place.
  depends_on = [
    data.google_compute_network.tenant_vpc,
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# --- Per-Instance Firewall Rules for Public Access ---

# Firewall rule to allow public SSH access to this specific instance.
# CRITICAL: Uses 'count' to apply only if os_type is Linux.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  # Targets instances with a specific tag unique to this deployment.
  target_tags = ["allow-ssh-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # WARNING: Broad access. Restrict source_ranges in production.
  description   = "Allow public SSH access to VM instance ${var.instance_name}"
}

# Firewall rule to allow public RDP access (for Windows instances).
# CRITICAL: Uses 'count' to apply only if os_type is Windows (0 in this case).
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"] # WARNING: Broad access. Restrict source_ranges in production.
  description   = "Allow public RDP access to VM instance ${var.instance_name}"
}

# Firewall rule to allow public WinRM access (for Windows instances).
# CRITICAL: Uses 'count' to apply only if os_type is Windows (0 in this case).
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"] # WARNING: Broad access. Restrict source_ranges in production.
  description   = "Allow public WinRM access to VM instance ${var.instance_name}"
}

# --- Outputs ---

# Output the private IP address of the deployed virtual machine.
# CRITICAL: Named "private_ip" as per instructions.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID.
# CRITICAL: Named "instance_id" as per instructions.
output "instance_id" {
  description = "The unique ID assigned to the virtual machine by GCP."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the network tags associated with the instance.
# CRITICAL: Named "network_tags" as per instructions.
output "network_tags" {
  description = "The network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key.
# CRITICAL: Named "private_ssh_key" and marked as sensitive as per instructions.
output "private_ssh_key" {
  description = "The private SSH key for accessing the virtual machine (sensitive)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}

# Output the name of the created unique subnetwork.
output "subnet_name" {
  description = "The name of the created Google Cloud subnetwork for this instance."
  value       = google_compute_subnetwork.this_subnet.name
}

# Output the CIDR range of the created unique subnetwork.
output "subnet_cidr" {
  description = "The CIDR range of the created Google Cloud subnetwork for this instance."
  value       = google_compute_subnetwork.this_subnet.ip_cidr_range
}