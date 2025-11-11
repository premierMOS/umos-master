# Configure the Google Cloud provider
# The 'project' attribute is intentionally omitted as per critical instruction.
provider "google" {
  region = var.region
}

# Configure the TLS provider for generating SSH keys
provider "tls" {}

# Configure the Random provider for generating unique subnet octets
provider "random" {}

# Declare Terraform variables for key configuration values, with default values
# pulled directly from the provided JSON configuration and critical instructions.

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcp-1"
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
  description = "Optional custom script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used in resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "image_name" {
  description = "The specific custom image name to use for the VM deployment."
  type        = string
  default     = "ubuntu-22-04-19271224598" # CRITICAL: As per instruction, NOT osImageId from JSON.
}

# Generate a new SSH private key for administrative access
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: 'comment' argument is forbidden for tls_private_key resource
}

# Generate a random integer for constructing a unique subnet CIDR block
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a dedicated VPC network for tenant isolation
resource "google_compute_network" "tenant_vpc" {
  name                    = "pmos-tenant-${var.tenant_id}-vpc"
  auto_create_subnetworks = false # CRITICAL: For full control over IP ranges
  description             = "Tenant-specific VPC network for secure isolation."
}

# Firewall rule to allow internal traffic within the tenant VPC
resource "google_compute_firewall" "allow_internal" {
  name    = "pmos-tenant-${var.tenant_id}-allow-internal"
  network = google_compute_network.tenant_vpc.name

  allow {
    protocol = "all" # CRITICAL: Allow all protocols for intra-tenant communication
  }

  source_ranges = ["10.0.0.0/8"] # CRITICAL: Private range covering all possible tenant subnets
  description   = "Allow all internal traffic within the tenant VPC."
}

# Firewall rule to allow secure SSH access via Google Cloud IAP
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "pmos-tenant-${var.tenant_id}-allow-iap-ssh"
  network = google_compute_network.tenant_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"] # CRITICAL: Allow TCP on port 22
  }

  source_ranges = ["35.235.240.0/20"] # CRITICAL: Google's IAP source range
  target_tags   = ["ssh-via-iap"]      # CRITICAL: Target instances with this tag
  description   = "Allow SSH access from Google Cloud IAP."
}

# Create a unique subnet for this specific deployment within the tenant VPC
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # CRITICAL: Dynamically generated IP range
  region        = var.region
  network       = google_compute_network.tenant_vpc.self_link # CRITICAL: Link to the tenant VPC
  description   = "Dedicated subnet for VM: ${var.instance_name}"
}

# Deploy the virtual machine instance
resource "google_compute_instance" "this_vm" {
  # CRITICAL: Omit 'project' attribute
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Using zone 'c' as a common default for example
  tags         = ["ssh-via-iap"]   # CRITICAL: Apply IAP tag for firewall rule

  boot_disk {
    initialize_params {
      image = var.image_name # CRITICAL: Use the specified custom image name
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link # CRITICAL: Deploy into the unique subnet
    # CRITICAL: Add empty access_config {} block to assign an ephemeral public IP for agent connectivity
    access_config {}
  }

  # CRITICAL: metadata_startup_script for custom scripts on GCP
  metadata = {
    ssh-keys             = "packer:${tls_private_key.admin_ssh.public_key_openssh}" # CRITICAL: SSH key for admin access
    startup-script       = var.custom_script                                         # CRITICAL: User data/custom script
  }

  # CRITICAL: Service account with cloud-platform scope for agents
  service_account {
    scopes = ["cloud-platform"]
  }

  # CRITICAL: Set deletion protection as false as per instructions
  deletion_protection = false

  lifecycle {
    ignore_changes = [
      # Ignore changes to the instance's service_account.access_config to prevent
      # Terraform from attempting to re-add or modify it if it's managed externally
      # or automatically assigned. This is often necessary for GCP instances.
      service_account[0].access_config,
    ]
  }

  description = "Virtual machine deployed with custom configuration for tenant ${var.tenant_id}."
}

# Output the private IP address of the deployed virtual machine
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID
output "instance_id" {
  description = "The unique ID assigned to the virtual machine by GCP."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the generated private SSH key, marked as sensitive
output "private_ssh_key" {
  description = "The private SSH key used to access the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # CRITICAL: Mark as sensitive
}