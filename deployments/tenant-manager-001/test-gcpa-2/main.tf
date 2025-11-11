# Configure the Google Cloud provider
provider "google" {
  region = var.region
  # The 'project' attribute is intentionally omitted as per critical instructions
}

# Required providers block to declare Google and Random providers
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
  }
}

# Declare Terraform variables for key configuration values, with default values from JSON
variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpa-2"
}

variable "region" {
  description = "Google Cloud region where the VM will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "User data script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "image_name" {
  description = "The specific custom image name to use for the VM."
  type        = string
  # CRITICAL INSTRUCTION: Use the hardcoded image name provided, not from JSON osImageId
  default     = "ubuntu-22-04-19271224598"
}

# Generate an SSH key pair for administrative access
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: 'comment' argument is forbidden for tls_private_key
}

# Resource to generate a random octet for the subnet IP range
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a dedicated VPC network for tenant isolation
resource "google_compute_network" "tenant_vpc" {
  name                    = "pmos-tenant-${var.tenant_id}-vpc"
  auto_create_subnetworks = false # CRITICAL: Manual subnet control
  description             = "VPC for tenant ${var.tenant_id}"
}

# Firewall rule to allow internal traffic within the tenant VPC
resource "google_compute_firewall" "allow_internal" {
  name    = "pmos-tenant-${var.tenant_id}-allow-internal"
  network = google_compute_network.tenant_vpc.name
  description = "Allow all protocols for intra-tenant communication"

  allow {
    protocol = "all"
  }

  source_ranges = ["10.0.0.0/8"] # Covers all possible tenant subnets
}

# Firewall rule to allow SSH access via Google Cloud IAP
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "pmos-tenant-${var.tenant_id}-allow-iap-ssh"
  network = google_compute_network.tenant_vpc.name
  description = "Allow SSH from Google IAP for secure console access"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] # Google's IAP source range
  target_tags   = ["ssh-via-iap"]    # CRITICAL: Target instances with this tag
}

# Create a unique subnet for this specific deployment within the tenant VPC
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # CRITICAL: Dynamic IP range
  region        = var.region
  network       = google_compute_network.tenant_vpc.self_link
  description   = "Unique subnet for instance ${var.instance_name}"
}

# Deploy the Google Compute Engine virtual machine instance
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # GCP requires a zone; appending '-a' for example
  description  = "Tenant VM deployed using Terraform"

  # CRITICAL: Omit the 'project' attribute from the instance block as per instructions

  # Boot disk configuration, using the specified custom image
  boot_disk {
    initialize_params {
      image = var.image_name # CRITICAL: Use the provided exact image name
    }
  }

  # CRITICAL: Network interface configuration
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link # Attach to the unique subnet
    # CRITICAL: This empty block assigns an ephemeral public IP
    access_config {
    }
  }

  # CRITICAL: Service account configuration with required scopes
  service_account {
    # CRITICAL: This block MUST NOT contain an access_config
    scopes = ["cloud-platform"] # Provides broad access; fine-tune for production
  }

  # Apply the IAP tag for firewall rules
  tags = ["ssh-via-iap"]

  # CRITICAL: Pass the custom script as metadata_startup_script
  metadata = {
    ssh-keys               = "packer:${tls_private_key.admin_ssh.public_key_openssh}" # For SSH access
    startup-script         = var.custom_script
    metadata_startup_script = var.custom_script # Alias for startup-script, common for user data
  }

  # CRITICAL: Set deletion_protection to false as per instructions
  deletion_protection = false

  # Allow instance to be created even if image is not publicly available or if it's a custom image.
  # This is often default behavior with custom images but good to be explicit.
  # scheduling {
  #   automatic_restart   = true
  #   on_host_maintenance = "MIGRATE"
  # }
}

# Output block to expose the private IP address of the VM
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output block to expose the cloud provider's native instance ID
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

# Output block to expose the generated private SSH key, marked as sensitive
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # CRITICAL: Mark as sensitive to prevent plain-text logging
}