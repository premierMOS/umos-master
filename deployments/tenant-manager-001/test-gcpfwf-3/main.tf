# Terraform HCL script to deploy a Google Cloud Platform (GCP) virtual machine
# based on the provided JSON configuration.
# This script adheres to secure, private cloud infrastructure as code principles
# with a focus on tenant isolation and controlled access.

# Configure Terraform required providers and their versions
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

# Configure the Google Cloud provider.
# CRITICAL: The 'project' attribute is intentionally omitted here and in the
# google_compute_instance resource to rely on the gcloud CLI's default project
# or the project specified in the environment for better flexibility and isolation.
provider "google" {
  region = var.region
  # Uncomment and configure 'credentials' if using a service account key file
  # credentials = file("path/to/your/service_account_key.json")
}

# -----------------------------------------------------------------------------
# INPUT VARIABLES
# These variables define the key configurable aspects of the virtual machine
# deployment, with default values directly sourced from the JSON configuration.
# This ensures the script is immediately runnable without interactive prompts.
# -----------------------------------------------------------------------------

variable "instance_name" {
  type        = string
  default     = "test-gcpfwf-3"
  description = "Name of the virtual machine instance."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region where resources will be deployed."
}

variable "vm_size" {
  type        = string
  default     = "e2-micro"
  description = "Machine type for the virtual machine."
}

variable "tenant_id" {
  type        = string
  default     = "tenant-manager-001"
  description = "Unique identifier for the tenant, used for naming shared resources."
}

variable "os_type" {
  type        = string
  default     = "Linux" # Derived from os.type in JSON
  description = "Operating system type (e.g., 'Linux' or 'Windows')."
}

variable "custom_script" {
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to run on instance startup (user data/metadata startup script)."
}

variable "gcp_image_name" {
  type        = string
  # CRITICAL: As per instructions, this is the exact and complete cloud image name to use.
  default     = "ubuntu-22-04-19271224598"
  description = "The exact name of the custom GCP image to use for the VM."
}

# -----------------------------------------------------------------------------
# SSH KEY PAIR GENERATION (FOR LINUX DEPLOYMENTS)
# A TLS private key resource is used to generate an SSH key pair for secure
# administrative access to Linux instances. The private key is outputted as
# a sensitive value.
# -----------------------------------------------------------------------------

resource "tls_private_key" "admin_ssh" {
  # Specifies the algorithm for the private key. RSA is commonly used.
  algorithm = "RSA"
  # Sets the bit length for the RSA key. 4096 bits provide strong encryption.
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
  # Do NOT add a 'comment' argument here.
}

# -----------------------------------------------------------------------------
# GCP TENANT ISOLATION AND SHARED INFRASTRUCTURE (GET-OR-CREATE PATTERN)
# This section implements a "get-or-create" pattern for shared tenant VPC and
# base firewall rules using 'null_resource' with 'local-exec' provisioners.
# This ensures idempotency and prevents "resource already exists" errors when
# deploying concurrently or repeatedly within the same project/tenant context.
# -----------------------------------------------------------------------------

# Data source to retrieve the current GCP project ID.
# This is necessary for 'gcloud' commands in local-exec provisioners.
data "google_project" "project" {}

# Null resource to provision the tenant-specific VPC network using gcloud.
# It attempts to describe the network first; if it doesn't exist (indicated by '||'),
# it proceeds to create it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to retrieve the tenant-specific VPC network created by the provisioner.
# CRITICAL: 'depends_on' ensures this data source is only read after the
# 'vpc_provisioner' has completed, guaranteeing the network exists.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = data.google_project.project.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to provision a shared firewall rule allowing internal VPC traffic.
# This rule permits all traffic between resources within the 10.0.0.0/8 CIDR range.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  # Ensure the VPC exists before attempting to create firewall rules for it.
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to provision a shared firewall rule allowing SSH access via Google's Identity-Aware Proxy (IAP).
# This rule permits SSH (TCP port 22) from IAP's public IP range to instances tagged 'ssh-via-iap'.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  # Ensure the VPC exists before attempting to create firewall rules for it.
  depends_on = [null_resource.vpc_provisioner]
}

# Random integer generator to create a unique third octet for the subnet IP range.
# This helps prevent IP range conflicts during concurrent deployments.
resource "random_integer" "subnet_octet" {
  min = 2  # Start from 2 to avoid common network/broadcast addresses.
  max = 254 # End before 255.
}

# Create a unique subnet for this specific deployment within the tenant VPC.
# The IP CIDR range is dynamically generated to ensure uniqueness.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  # Enables private IP access to Google APIs and services from VMs in this subnet.
  private_ip_google_access = true
  # Ensure the tenant VPC is provisioned before creating a subnet within it.
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# -----------------------------------------------------------------------------
# VIRTUAL MACHINE DEPLOYMENT
# Defines the primary virtual machine instance, named "this_vm".
# -----------------------------------------------------------------------------

resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  # GCP instances require a specific zone. Appending '-c' to the region provides a default zone.
  zone         = "${var.region}-c"

  # CRITICAL: OMIT the 'project' attribute to rely on the provider's configuration.
  # Disables deletion protection, allowing the instance to be deleted without manual override.
  deletion_protection = false

  # Boot disk configuration for the virtual machine.
  boot_disk {
    initialize_params {
      # CRITICAL: Uses the exact custom image name specified in instructions.
      image = var.gcp_image_name
    }
  }

  # Network interface configuration.
  network_interface {
    # Associates the instance with the dynamically created subnet.
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: NO 'access_config' block should be present here.
    # The instance will only have a private IP address. Connectivity for SSH/RDP
    # is expected via IAP or private network routes.
  }

  # Service account for the instance, granting it 'cloud-platform' scope for full
  # access to Google Cloud resources.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Conditional network tags applied to the instance.
  # 'ssh-via-iap' is for IAP connectivity on Linux. 'allow-ssh/rdp/winrm' tags
  # are for instance-specific firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Instance metadata, including SSH keys for Linux and startup script.
  metadata = merge(
    # SSH public key for Linux instances, formatted for GCP's 'ssh-keys' metadata.
    var.os_type == "Linux" ? {
      "ssh-keys" = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
    } : {},
    # Startup script to be executed when the instance starts up.
    var.custom_script != "" ? {
      "startup-script" = var.custom_script
    } : {}
  )

  # Explicitly depends on the subnet being created before the instance.
  depends_on = [
    google_compute_subnetwork.this_subnet
  ]
}

# -----------------------------------------------------------------------------
# PER-INSTANCE FIREWALL RULES
# These firewall rules provide isolated public access to the specific VM.
# They are conditionally created based on the OS type.
# -----------------------------------------------------------------------------

# Firewall rule to allow public SSH access (TCP 22) to this specific Linux instance.
# This rule is only created if the OS type is Linux.
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0

  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Allows access from any IP address.
  target_tags   = ["allow-ssh-${var.instance_name}"] # Targets this specific instance's tag.

  # Explicit dependency on the VM ensures tags are applied before firewall creation.
  depends_on = [google_compute_instance.this_vm]
}

# Firewall rule to allow public RDP access (TCP 3389) to this specific Windows instance.
# This rule is only created if the OS type is Windows.
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0

  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]

  depends_on = [google_compute_instance.this_vm]
}

# Firewall rule to allow public WinRM access (TCP 5985-5986) to this specific Windows instance.
# This rule is only created if the OS type is Windows.
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0

  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]

  depends_on = [google_compute_instance.this_vm]
}

# -----------------------------------------------------------------------------
# OUTPUTS
# These outputs provide important information about the deployed resources,
# enabling easy retrieval and integration with other tools or scripts.
# -----------------------------------------------------------------------------

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID (GCP instance ID)."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags applied to the instance for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

# CRITICAL: This output exposes the generated private SSH key. It is marked as
# sensitive to prevent it from being displayed in plaintext in the console
# or stored in state files without proper encryption.
output "private_ssh_key" {
  description = "The private SSH key generated for administrative access. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}