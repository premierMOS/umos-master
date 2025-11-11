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

# --- Provider Configuration ---
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Input Variables ---

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwm-2"
}

variable "region" {
  description = "The GCP region to deploy resources in."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone to deploy the virtual machine in. Defaults to the first zone in the specified region."
  type        = string
  default     = "us-central1-a" # A common default zone for us-central1
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "The unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "A custom script to execute on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "project_id" {
  description = "The GCP project ID where resources will be deployed."
  type        = string
  default     = "umos-ab24d"
}

# --- Random Resources for Unique Subnet CIDR ---

resource "random_integer" "subnet_octet_2" {
  # Generates a random integer between 1 and 254 for the second octet of the subnet CIDR.
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

resource "random_integer" "subnet_octet_3" {
  # Generates a random integer between 0 and 254 for the third octet of the subnet CIDR.
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# --- GCP Tenant Networking - Get-or-Create VPC Network ---

resource "null_resource" "vpc_provisioner" {
  # Idempotently creates the tenant VPC network using gcloud CLI if it doesn't already exist.
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

data "google_compute_network" "tenant_vpc" {
  # Reads the details of the tenant VPC network after it's ensured to exist.
  name    = "pmos-tenant-${var.tenant_id}-vpc"
  project = var.project_id
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

# --- GCP Tenant Networking - Get-or-Create Shared Firewall Rules ---

resource "null_resource" "allow_internal_provisioner" {
  # Idempotently creates a firewall rule for internal traffic within the tenant VPC.
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

resource "null_resource" "allow_iap_ssh_provisioner" {
  # Idempotently creates a firewall rule to allow SSH via Identity-Aware Proxy (IAP).
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# --- Unique Subnet for the Instance ---

resource "google_compute_subnetwork" "this_subnet" {
  # Creates a new subnet for this specific instance within the tenant VPC.
  project       = var.project_id
  region        = var.region
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on = [
    data.google_compute_network.tenant_vpc,
    random_integer.subnet_octet_2,
    random_integer.subnet_octet_3
  ]
}

# --- SSH Key Pair Generation (for Linux only) ---

resource "tls_private_key" "admin_ssh" {
  # Generates an SSH private key for Linux instances.
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

# --- Per-Instance Firewall Rules ---

resource "google_compute_firewall" "allow_public_ssh" {
  # Allows public SSH access to this specific Linux instance.
  count   = var.os_type == "Linux" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

resource "google_compute_firewall" "allow_public_rdp" {
  # Allows public RDP access to this specific Windows instance.
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

resource "google_compute_firewall" "allow_public_winrm" {
  # Allows public WinRM access to this specific Windows instance.
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# --- Virtual Machine Deployment ---

resource "google_compute_instance" "this_vm" {
  # Deploys the virtual machine instance on GCP.
  project          = var.project_id
  zone             = var.zone
  name             = var.instance_name
  machine_type     = var.vm_size
  deletion_protection = false # As per instruction

  # Custom image definition
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Exact custom image name
    }
  }

  # Network interface configuration
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      // Ephemeral public IP is assigned here as per CRITICAL GCP networking instructions.
    }
  }

  # Service account for Cloud API access
  service_account {
    scopes = ["cloud-platform"]
  }

  # Instance tags for firewall rules
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for startup script and SSH keys
  metadata = {
    # Custom startup script
    startup-script = var.custom_script
    # SSH public key for Linux instances
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # CRITICAL DEPENDENCY INSTRUCTION: Explicitly depend on conditionally created resources.
  depends_on = [
    tls_private_key.admin_ssh,             # Handles count = 0 gracefully
    google_compute_subnetwork.this_subnet,
    google_compute_firewall.allow_public_ssh,  # Handles count = 0 gracefully
    google_compute_firewall.allow_public_rdp,  # Handles count = 0 gracefully
    google_compute_firewall.allow_public_winrm # Handles count = 0 gracefully
  ]
}

# --- Outputs ---

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "public_ip" {
  description = "The public IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags applied to the instance."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The private SSH key generated for Linux instances."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance."
  sensitive   = true
}