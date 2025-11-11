# This Terraform script deploys a Google Cloud Platform (GCP) virtual machine
# with specific networking, security, and image configurations.

# Configure the Google Cloud provider.
# CRITICAL OMISSION: The 'project' attribute is intentionally omitted from the provider block
# as per tenant isolation requirements, allowing it to be implicitly picked up
# from the environment (e.g., GOOGLE_CLOUD_PROJECT, gcloud config).
provider "google" {}

# Configure the TLS provider for generating SSH keys.
provider "tls" {}

# Configure the Random provider for generating unique subnet CIDR ranges.
provider "random" {}

# Declare Terraform variables with default values directly from the JSON configuration.
# This prevents interactive prompts for input during 'terraform plan' or 'terraform apply'.

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpa-1"
}

variable "region" {
  description = "GCP region where the resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "User data script to run on instance startup (GCP metadata startup-script)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "Identifier for the tenant, used for naming tenant-specific resources."
  type        = string
  default     = "tenant-manager-001"
}

# Local values for common configurations or computed names.
locals {
  # CRITICAL IMAGE NAME INSTRUCTION: Use the exact and complete cloud image name provided.
  # This value is fixed for this deployment and should not be changed.
  image_name = "ubuntu-22-04-19271224598"
}

# FOR LINUX DEPLOYMENTS ONLY: Generate a unique SSH key pair for administrative access.
# The 'tls_private_key' resource does not support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Generate a random integer to construct a unique subnet IP CIDR range.
# This ensures that each deployment gets a distinct subnet within the tenant VPC,
# preventing IP conflicts during concurrent deployments.
resource "random_integer" "subnet_octet" {
  min = 2   # Start from 2 to avoid common network addresses like .0.0 or .1.0
  max = 254 # End before 255 to allow for future expansion

  # Using a keeper to regenerate the random number if the instance name changes,
  # ensuring subnet uniqueness per instance deployment.
  keepers = {
    instance_name = var.instance_name
  }
}

# CRITICAL GCP NETWORKING: Create a dedicated VPC network for tenant isolation.
resource "google_compute_network" "tenant_vpc" {
  name                    = "pmos-tenant-${var.tenant_id}-vpc"
  auto_create_subnetworks = false # CRITICAL: Disable auto-creation for full control over IP ranges.
  routing_mode            = "REGIONAL"
  description             = "Dedicated VPC for tenant ${var.tenant_id} to ensure isolation."
}

# CRITICAL GCP NETWORKING: Create a firewall rule to allow all internal traffic
# within the tenant's dedicated VPC. This facilitates intra-tenant communication.
resource "google_compute_firewall" "allow_internal" {
  name    = "pmos-tenant-${var.tenant_id}-allow-internal"
  network = google_compute_network.tenant_vpc.name

  allow {
    protocol = "all" # CRITICAL: Allow all protocols for intra-tenant communication.
  }

  source_ranges = ["10.0.0.0/8"] # CRITICAL: Covers all possible private IP ranges (RFC 1918).
  description   = "Allows all traffic within the PMOS tenant VPC for internal communication."
}

# CRITICAL GCP NETWORKING: Create a firewall rule to allow secure SSH access
# via Google Cloud's Identity-Aware Proxy (IAP).
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "pmos-tenant-${var.tenant_id}-allow-iap-ssh"
  network = google_compute_network.tenant_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"] # CRITICAL: Allow TCP traffic on port 22 (SSH).
  }

  source_ranges = ["35.235.240.0/20"] # CRITICAL: Google's official IAP source IP range.
  target_tags   = ["ssh-via-iap"]    # CRITICAL: Targets instances tagged with 'ssh-via-iap'.
  description   = "Allows SSH access to instances tagged 'ssh-via-iap' from Google's IAP."
}

# CRITICAL GCP NETWORKING: Create a unique subnet for this specific deployment
# within the tenant's VPC. This prevents IP conflicts with other deployments.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # CRITICAL: Dynamically generated unique IP range.
  region        = var.region
  network       = google_compute_network.tenant_vpc.self_link # CRITICAL: Associate with the tenant VPC.
  description   = "Unique subnet for ${var.instance_name} within the tenant VPC."
}

# Deploy the virtual machine instance.
# CRITICAL: The primary compute resource MUST be named "this_vm".
resource "google_compute_instance" "this_vm" {
  # CRITICAL OMISSION: The 'project' attribute is intentionally omitted from the resource block.
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Deploying in zone 'c' of the specified region.
                                   # For production, consider making the zone configurable or dynamic.

  # CRITICAL STRUCTURE & NETWORKING: Define the network interface for the VM.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link # CRITICAL: Attach to the unique subnet.

    # CRITICAL NETWORKING REQUIREMENT: Include an empty 'access_config' block
    # to assign an ephemeral public IP address to the instance.
    access_config {
      # This empty block assigns an ephemeral public IP for external connectivity
      # needed by management agents or for inbound IAP connections. DO NOT MOVE IT.
    }
  }

  # CRITICAL STRUCTURE: Define the service account for the VM.
  # This block MUST NOT contain an access_config.
  service_account {
    scopes = ["cloud-platform"] # Grants broad access; refine for production with least privilege principle.
  }

  # Boot disk configuration.
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION: Use the exact custom cloud image name provided.
      # For GCP, if the image is in the current project, just the name is sufficient.
      image = local.image_name
      size  = 50 # Default disk size in GB, can be parameterized if needed.
      type  = "pd-ssd" # Using SSD for better performance.
    }
  }

  # Metadata configuration for startup script and SSH keys.
  metadata = {
    # FOR LINUX DEPLOYMENTS ONLY: Add 'ssh-keys' metadata entry for SSH key.
    # The value is formatted for GCP to associate the public key with a user (packer).
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
    # USER DATA/CUSTOM SCRIPT: For GCP, use the 'startup-script' metadata key.
    startup-script = var.custom_script
  }

  # CRITICAL GCP NETWORKING: Apply the 'ssh-via-iap' tag to enable SSH access
  # through the IAP firewall rule.
  tags = ["ssh-via-iap"]

  # CRITICAL: 'deletion_protection' must be 'false' as per instructions.
  deletion_protection = false

  description = "VM deployed for tenant ${var.tenant_id} as ${var.instance_name}."
}

# Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the created virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the generated private SSH key.
# This output MUST be marked as sensitive to prevent it from being displayed
# in plain text in Terraform logs or state file during normal operations.
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM (sensitive)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # CRITICAL: Mark this output as sensitive.
}