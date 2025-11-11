# Terraform configuration block
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Use a suitable version constraint
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Use a suitable version constraint
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0" # Use a suitable version constraint
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # Use a suitable version constraint
    }
  }
}

# Google Cloud Provider Configuration
# The 'project' attribute is intentionally omitted as per critical instructions,
# relying on default project configuration (e.g., from gcloud CLI or environment variables).
provider "google" {
  region = var.region
  # Credentials would typically be sourced from environment variables (GOOGLE_CREDENTIALS, GOOGLE_PROJECT)
  # or from a service account key file.
}

# ----------------------------------------------------------------------------------------------------------------------
# INPUT VARIABLES
# These variables define the configuration for the virtual machine and associated resources.
# All variables include default values directly from the provided JSON configuration.
# ----------------------------------------------------------------------------------------------------------------------

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azurefwa-1"
}

variable "region" {
  description = "The Google Cloud region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for naming shared tenant resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux" # From os.type in JSON
}

variable "custom_script" {
  description = "A custom script to be executed on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# ----------------------------------------------------------------------------------------------------------------------
# DATA SOURCES
# These blocks retrieve existing information from Google Cloud or provide dynamic values.
# ----------------------------------------------------------------------------------------------------------------------

# Data source to retrieve the current Google project ID.
data "google_project" "project" {}

# Get-or-Create Tenant VPC Network Provisioner:
# This null_resource uses local-exec to ensure the tenant VPC network exists before Terraform tries to read it.
# It uses gcloud CLI to first describe the network, and if it doesn't exist (exit code != 0), it creates it.
# The '&>/dev/null' is critical to suppress command output and rely only on the exit code for the '||' condition.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the tenant VPC network.
# Explicitly depends on the null_resource to ensure the network is created before attempting to read it.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = data.google_project.project.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# Get-or-Create Shared Firewall Rule Provisioner (Allow Internal):
# Ensures a firewall rule allowing all internal traffic within 10.0.0.0/8 exists for the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Get-or-Create Shared Firewall Rule Provisioner (Allow IAP SSH):
# Ensures a firewall rule allowing SSH via IAP exists for the tenant VPC, targeting instances with 'ssh-via-iap' tag.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# ----------------------------------------------------------------------------------------------------------------------
# RESOURCES
# These blocks define the Google Cloud resources to be deployed.
# ----------------------------------------------------------------------------------------------------------------------

# Generate a random integer for the subnet's second octet to ensure unique CIDR ranges.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a unique subnetwork within the tenant VPC for this deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [data.google_compute_network.tenant_vpc] # Explicit dependency for safety
}

# Generate an SSH key pair for Linux instances.
# The 'comment' argument is explicitly forbidden for 'tls_private_key'.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create a firewall rule to allow public SSH access to this specific instance (if Linux).
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]

  depends_on = [data.google_compute_network.tenant_vpc]
}

# Create a firewall rule to allow public RDP access to this specific instance (if Windows).
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]

  depends_on = [data.google_compute_network.tenant_vpc]
}

# Create a firewall rule to allow public WinRM access to this specific instance (if Windows).
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]

  depends_on = [data.google_compute_network.tenant_vpc]
}

# Google Compute Engine Virtual Machine Instance
resource "google_compute_instance" "this_vm" {
  name                 = var.instance_name
  machine_type         = var.vm_size
  zone                 = "${var.region}-a" # Defaulting to zone 'a' within the specified region.
  deletion_protection  = false              # As per critical instructions.
  # The 'project' attribute is intentionally omitted as per critical instructions.

  # Boot disk configuration, using the specific image name provided in the instructions.
  boot_disk {
    initialize_params {
      # CRITICAL: Use the exact cloud image name provided in the instructions.
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link

    # CRITICAL: This empty block assigns an ephemeral public IP. DO NOT MOVE IT.
    access_config { }
  }

  # Service account configuration with required scopes for cloud APIs.
  # CRITICAL: This block MUST NOT contain an access_config.
  service_account {
    scopes = ["cloud-platform"] # Full access to all Cloud APIs, can be restricted if needed.
  }

  # Metadata for startup script and SSH keys.
  metadata = merge(
    var.custom_script != "" ? { startup-script = var.custom_script } : {}, # Pass custom script if provided.
    var.os_type == "Linux" ? { ssh-keys = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" } : {} # Add SSH key for Linux instances.
  )

  # Instance tags for firewall rules and IAP access.
  # Conditional tags based on OS type for public access.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm,
    tls_private_key.admin_ssh # Ensure key is generated before metadata is applied.
  ]
}

# ----------------------------------------------------------------------------------------------------------------------
# OUTPUTS
# These outputs provide important information about the deployed resources.
# ----------------------------------------------------------------------------------------------------------------------

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The unique identifier of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The private SSH key generated for accessing the Linux virtual machine."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux VM"
  sensitive   = true
}