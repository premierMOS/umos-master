# Configure the Google Cloud provider
# The project attribute is intentionally omitted as per instructions for tenant isolation.
provider "google" {
  region = var.region
}

# Required providers block for Terraform
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Specify a compatible version
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Specify a compatible version
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # Specify a compatible version
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0" # Specify a compatible version
    }
  }
}

# --- Variables Block ---

# Name of the virtual machine instance
variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpfwi-2"
}

# Google Cloud Platform region for resource deployment
variable "region" {
  description = "The Google Cloud Platform region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

# Size/type of the virtual machine
variable "vm_size" {
  description = "The machine type for the virtual machine instance."
  type        = string
  default     = "e2-micro"
}

# Identifier for the tenant, used for resource naming and isolation
variable "tenant_id" {
  description = "Unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

# Operating system type (Linux or Windows)
variable "os_type" {
  description = "The operating system type of the VM (Linux or Windows)."
  type        = string
  default     = "Linux" # Default from JSON configuration
}

# Custom script to be executed on instance startup
variable "custom_script" {
  description = "A custom script to be executed on the VM instance at startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Data Sources ---

# Data source to get the current Google Cloud project ID.
# This is required for gcloud commands in null_resources.
data "google_project" "project" {}

# Data source to retrieve details of the tenant VPC network.
# It depends on the null_resource that provisions the VPC to ensure it exists before being read.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# --- Shared Tenant Resource Provisioning (Get-or-Create Idempotent Pattern) ---

# Null resource to get-or-create the tenant-specific VPC network.
# Uses gcloud CLI to first describe the network; if it doesn't exist (indicated by failure '||'), it creates it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Null resource to get-or-create the shared firewall rule for internal traffic within the VPC.
# This rule allows all protocols/ports from within the broad 10.0.0.0/8 private IP range.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to get-or-create the shared firewall rule for IAP SSH access.
# This rule allows SSH connections via Google Cloud IAP, targeting instances with 'ssh-via-iap' tag.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [null_resource.vpc_provisioner]
}

# --- Network Resources for this specific deployment ---

# Generate a random integer between 2 and 254 to create a unique third octet for the subnet's IP range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a unique subnetwork for this specific VM instance.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [null_resource.vpc_provisioner] # Ensure the VPC is provisioned before creating a subnet in it
}

# --- SSH Key Pair Generation (For Linux VMs) ---

# Generate a new TLS private key to be used for SSH access to Linux instances.
# The 'comment' argument is explicitly forbidden as per instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # The 'comment' attribute is forbidden by critical instructions.
}

# --- Virtual Machine Deployment ---

# Google Compute Engine Virtual Machine instance
resource "google_compute_instance" "this_vm" {
  name                = var.instance_name
  machine_type        = var.vm_size
  zone                = "${var.region}-c" # Deploying to a specific zone within the region (e.g., us-central1-c)
  deletion_protection = false              # Explicitly set to false as per instructions

  # Boot disk configuration, using the specified custom image name.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Use the exact image name specified in the instructions.
      size  = 50                         # Default disk size, can be made a variable if needed
      type  = "pd-ssd"                   # Use SSD for better performance and general use cases
    }
  }

  # Network interface configuration.
  # CRITICAL STRUCTURE: 'access_config {}' MUST be directly within 'network_interface'.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link

    # Empty access_config block assigns an ephemeral public IP, as required for external connectivity.
    access_config {}
  }

  # Service account for the VM, granting necessary cloud-platform scopes.
  # CRITICAL STRUCTURE: This block MUST NOT contain an 'access_config'.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Tags for applying firewall rules and other metadata.
  # Conditional tags are applied based on the 'os_type' variable.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for SSH keys (for Linux VMs) and startup script.
  metadata = {
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh.public_key_openssh}" : null
  }
  metadata_startup_script = var.custom_script # Pass the custom script to the instance for execution on startup.
}

# --- Per-Instance Firewall Rules for Public Access ---

# Firewall rule to allow public SSH access (TCP port 22) for Linux instances.
# This rule is created only if the OS type is "Linux".
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"] # Allows access from any IP address
  target_tags   = ["allow-ssh-${var.instance_name}"]
  depends_on    = [google_compute_instance.this_vm] # Ensure VM exists and tags are applied
}

# Firewall rule to allow public RDP access (TCP port 3389) for Windows instances.
# This rule is created only if the OS type is "Windows".
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
  source_ranges = ["0.0.0.0/0"] # Allows access from any IP address
  target_tags   = ["allow-rdp-${var.instance_name}"]
  depends_on    = [google_compute_instance.this_vm] # Ensure VM exists and tags are applied
}

# Firewall rule to allow public WinRM access (TCP ports 5985-5986) for Windows instances.
# This rule is created only if the OS type is "Windows".
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }
  source_ranges = ["0.0.0.0/0"] # Allows access from any IP address
  target_tags   = ["allow-winrm-${var.instance_name}"]
  depends_on    = [google_compute_instance.this_vm] # Ensure VM exists and tags are applied
}

# --- Outputs ---

# Expose the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the VM instance."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the VM instance in Google Cloud."
  value       = google_compute_instance.this_vm.instance_id
}

# Expose the network tags assigned to the instance.
output "network_tags" {
  description = "The network tags assigned to the VM instance."
  value       = google_compute_instance.this_vm.tags
}

# Expose the generated private SSH key for Linux instances.
# This output is critically marked as sensitive to prevent it from being displayed in plain text
# in Terraform logs or state output without explicit commands.
output "private_ssh_key" {
  description = "The private SSH key generated for accessing the Linux VM. KEEP THIS SECURE!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}