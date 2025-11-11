# Terraform configuration for Google Cloud Platform VM deployment

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

# Configure the Google Cloud provider
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Input Variables ---
# These variables define key configuration values, with default values directly from the JSON.
# This prevents interactive prompts during `terraform plan` or `terraform apply`.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwn-2"
}

variable "region" {
  description = "The Google Cloud region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (e.g., Linux, Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "A custom script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "project_id" {
  description = "The GCP project ID where resources will be deployed."
  type        = string
  default     = "umos-ab24d"
}

# --- Shared Tenant Networking (Get-or-Create Idempotent Resources) ---
# These null_resources use local-exec provisioners with gcloud to create VPC network
# and common firewall rules if they don't already exist, ensuring idempotency and
# preventing "resource already exists" errors for shared tenant infrastructure.

resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    # Check if VPC exists, if not, create it.
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    # Check if internal firewall rule exists, if not, create it.
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is provisioned first
}

resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    # Check if IAP SSH firewall rule exists, if not, create it.
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is provisioned first
}

# Data source to retrieve the shared tenant VPC network after it's provisioned.
data "google_compute_network" "tenant_vpc" {
  name    = "pmos-tenant-${var.tenant_id}-vpc"
  project = var.project_id
  depends_on = [null_resource.vpc_provisioner] # Explicitly depend on the VPC being created
}

# --- Unique Subnet for this Deployment ---
# Uses random integers to generate a unique CIDR range, preventing collisions
# in concurrent deployments within the same tenant VPC.

resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is created before subnet
}

# --- SSH Key Pair Generation (for Linux VMs only) ---
# Generates a new SSH key pair to securely access Linux instances.

resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Per-Instance Public Access Firewall Rules ---
# These firewall rules are specific to this instance, allowing public SSH/RDP/WinRM
# based on the OS type. They use instance-specific tags.

resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is created
}

resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is created
}

resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is created
}

# --- Virtual Machine Instance ---
# The primary compute resource for this deployment.

resource "google_compute_instance" "this_vm" {
  project           = var.project_id
  name              = var.instance_name
  machine_type      = var.vm_size
  zone              = "${var.region}-a" # Defaulting to zone 'a' within the region
  deletion_protection = false

  # Configure the boot disk for the VM.
  boot_disk {
    initialize_params {
      # CRITICAL: Using the exact custom image name provided.
      image = "ubuntu-22-04-19271224598"
      size  = 50 # Example disk size, adjust as needed
      type  = "pd-ssd" # Example disk type
    }
  }

  # Configure network interface.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # An empty access_config block assigns an ephemeral public IP.
    access_config {
    }
  }

  # Service account for the instance to interact with GCP services.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Apply instance tags for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for startup script and SSH keys.
  metadata = {
    # Pass custom script as startup-script metadata.
    startup-script = var.custom_script
    # For Linux, add SSH public key to metadata.
    # The 'count' for tls_private_key ensures this only runs for Linux.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # Explicit dependency on conditionally created SSH key.
  # Terraform correctly handles resources with count=0 in depends_on.
  depends_on = [
    tls_private_key.admin_ssh,
    google_compute_subnetwork.this_subnet,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner
  ]
}

# --- Outputs ---
# These outputs provide crucial information about the deployed VM.

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "public_ip" {
  description = "The public IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

output "instance_id" {
  description = "The unique ID of the virtual machine instance in GCP."
  value       = google_compute_instance.this_vm.instance_id
}

output "private_ssh_key" {
  description = "The private SSH key for accessing the Linux instance (sensitive)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A for Windows instances"
  sensitive   = true
}

output "network_tags" {
  description = "The network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}