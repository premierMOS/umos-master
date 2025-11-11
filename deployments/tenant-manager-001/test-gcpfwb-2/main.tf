# Providers configuration
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

# Google Cloud provider configuration.
# The 'project' attribute is intentionally OMITTED from this block as per instructions.
provider "google" {
  region = var.region
}

# Declare Terraform variables for key configuration values from the JSON.
# Each variable includes a 'default' value set directly from the provided configuration.

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwb-2"
}

variable "region" {
  description = "GCP region where the VM will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type for the instance (Linux or Windows)."
  type        = string
  default     = "Linux" # Derived from os.type in the JSON configuration
}

variable "custom_script" {
  description = "User data script or startup script to execute on instance boot."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "gcp_image_name" {
  description = "The exact and complete cloud image name to use for the VM."
  type        = string
  default     = "ubuntu-22-04-19271224598" # CRITICAL IMAGE NAME INSTRUCTION
}


# Data source to get the current Google Cloud project ID.
# This is required for gcloud commands in local-exec provisioners.
data "google_project" "project" {}

# Generate a random integer to create a unique third octet for the subnet's IP CIDR range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}


# CRITICAL GCP NETWORKING, CONNECTIVITY & TENANT ISOLATION INSTRUCTIONS:
# Implement a "get-or-create" pattern for shared tenant VPC network and firewall rules.
# This uses 'null_resource' with 'local-exec' provisioners calling the 'gcloud' CLI.
# The `>/dev/null 2>&1 ||` syntax makes the operation idempotent by describing first and creating only if it doesn't exist.

# Resource to provision or get the tenant-specific VPC network.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    # Trigger this provisioner if the tenant_id changes.
    tenant_id = var.tenant_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || \
      gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description="VPC for tenant ${var.tenant_id}"
    EOT
  }
}

# Data source to read the tenant VPC network data after it's ensured to exist.
# The explicit 'depends_on' ensures that Terraform waits for the 'null_resource' to complete.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Resource to provision or get the shared internal traffic firewall rule for the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    # Trigger if tenant_id or VPC self_link changes.
    tenant_id     = var.tenant_id
    vpc_self_link = data.google_compute_network.tenant_vpc.self_link
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || \
      gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8 --description="Allow all internal traffic within the tenant VPC"
    EOT
  }
  # Ensure VPC exists before attempting to create firewall rules for it.
  depends_on = [null_resource.vpc_provisioner]
}

# Resource to provision or get the shared IAP SSH firewall rule for the tenant VPC.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    # Trigger if tenant_id or VPC self_link changes.
    tenant_id     = var.tenant_id
    vpc_self_link = data.google_compute_network.tenant_vpc.self_link
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || \
      gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap --description="Allow SSH access via Google IAP for tenant resources"
    EOT
  }
  # Ensure VPC exists before attempting to create firewall rules for it.
  depends_on = [null_resource.vpc_provisioner]
}

# Create a NEW, unique subnet for THIS deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # Dynamic IP range
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  description   = "Dedicated subnet for instance ${var.instance_name}"

  # Ensure the tenant VPC and shared firewall rules are provisioned before creating this subnet.
  depends_on = [
    null_resource.vpc_provisioner,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# FOR LINUX DEPLOYMENTS ONLY: Generate an SSH key pair using 'tls_private_key'.
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0 # Only create if OS type is Linux
  algorithm = "RSA"
  rsa_bits  = 4096
}


# Primary compute resource named "this_vm".
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Deploying into a default zone within the specified region

  # CRITICAL: OMIT the 'project' attribute from the resource block as per instructions.
  # CRITICAL: Set 'deletion_protection = false'.
  deletion_protection = false

  # Boot disk configuration, using the specified custom image name.
  boot_disk {
    initialize_params {
      image = var.gcp_image_name # CRITICAL IMAGE NAME INSTRUCTION
    }
  }

  # CRITICAL STRUCTURE: network_interface and service_account blocks.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL NETWORKING REQUIREMENT: Include an empty 'access_config {}' block
    # to assign an ephemeral public IP address. DO NOT MOVE IT.
    access_config {}
  }

  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"]
  }

  # Add SSH key for Linux instances via metadata.
  # Pass the 'custom_script' to the instance's 'metadata_startup_script'.
  metadata = {
    # For GCP, the 'ssh-keys' metadata entry is formatted as 'user:public_key'.
    ssh-keys            = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
    metadata_startup_script = var.custom_script # User data/custom script argument for GCP
  }

  # Apply network tags conditionally based on OS type.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Explicitly depend on networking resources being ready.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# Create per-instance firewall rules for isolated public access.
# These rules are created conditionally based on the OS type.

# Public SSH Rule for Linux instances.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  description = "Allow public SSH access to the specific Linux instance ${var.instance_name}"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]

  # Ensure the instance and its tags are created before the firewall rule.
  depends_on = [google_compute_instance.this_vm]
}

# Public RDP Rule for Windows instances.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  description = "Allow public RDP access to the specific Windows instance ${var.instance_name}"

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]

  # Ensure the instance and its tags are created before the firewall rule.
  depends_on = [google_compute_instance.this_vm]
}

# Public WinRM Rule for Windows instances.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  description = "Allow public WinRM access to the specific Windows instance ${var.instance_name}"

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # Both HTTP and HTTPS WinRM ports
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]

  # Ensure the instance and its tags are created before the firewall rule.
  depends_on = [google_compute_instance.this_vm]
}


# Output blocks as required by the critical instructions.

# Output named "private_ip" exposing the private IP address of the created VM.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output named "instance_id" exposing the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

# NEW OUTPUT: Output named "network_tags" exposing the tags applied to the instance.
output "network_tags" {
  description = "The network tags applied to the VM instance."
  value       = google_compute_instance.this_vm.tags
}

# Output named "private_ssh_key" exposing the generated private key.
# This output is marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for Linux instances (sensitive)."
  # Conditionally output the key only if a Linux instance was deployed.
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive   = true
}