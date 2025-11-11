terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Configure the Google Cloud provider
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Terraform Variables Declaration ---

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwl-3"
}

variable "region" {
  description = "The Google Cloud region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "custom_script" {
  description = "A custom script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "project_id" {
  description = "The Google Cloud Project ID."
  type        = string
  default     = "umos-ab24d"
}

# --- GCP Tenant-wide Shared Network Resources (Get-or-Create Idempotently) ---

# Provisioner to get or create the tenant-specific VPC network.
# This ensures the VPC exists before we try to reference it.
resource "null_resource" "vpc_provisioner" {
  # Trigger only when the project_id or tenant_id changes
  triggers = {
    project_id = var.project_id
    tenant_id  = var.tenant_id
  }

  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant VPC network, depending on its creation by the null_resource.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# Provisioner to get or create a shared firewall rule for internal network traffic.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    project_id  = var.project_id
    tenant_id   = var.tenant_id
    network_id  = data.google_compute_network.tenant_vpc.id
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Provisioner to get or create a shared firewall rule for IAP SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    project_id  = var.project_id
    tenant_id   = var.tenant_id
    network_id  = data.google_compute_network.tenant_vpc.id
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Unique Subnet for this Deployment ---

# Generates a random integer for the second octet of the subnet's IP range.
resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Generates a random integer for the third octet of the subnet's IP range.
resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# Creates a unique subnetwork for this VM instance within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [data.google_compute_network.tenant_vpc] # Ensure VPC exists
}

# --- SSH Key Pair Generation (For Linux VMs Only) ---

# Generates a new RSA private key for SSH access.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

# --- Virtual Machine Deployment ---

resource "google_compute_instance" "this_vm" {
  project         = var.project_id
  name            = var.instance_name
  machine_type    = var.vm_size
  zone            = "${var.region}-a" # Deploying to a specific zone within the region
  deletion_protection = false # Allows instance to be deleted

  # Boot disk configuration, using the specified custom image.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # Assign an ephemeral public IP address for direct connectivity.
    access_config {
      // Ephemeral public IP is assigned here.
    }
  }

  # Service account with necessary scopes for instance management.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Apply network tags based on OS type for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata block for startup script and SSH keys.
  metadata = merge(
    {
      "startup-script" = var.custom_script
    },
    var.os_type == "Linux" ? {
      "ssh-keys" = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
    } : {}
  )

  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_iap_ssh_provisioner, # Ensure IAP firewall rule is created for Linux
    null_resource.allow_internal_provisioner  # Ensure internal firewall rule is created
  ]
}

# --- Per-Instance Public Access Firewall Rules ---

# Firewall rule to allow public SSH access to this specific Linux instance.
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0

  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]

  depends_on = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public RDP access to this specific Windows instance.
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0

  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]

  depends_on = [data.google_compute_network.tenant_vpc]
}

# Firewall rule to allow public WinRM access to this specific Windows instance.
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0

  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]

  depends_on = [data.google_compute_network.tenant_vpc]
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
  description = "The network tags associated with the virtual machine."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The private SSH key for accessing the Linux VM. KEEP THIS SECURE!"
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A (Windows VM)"
  sensitive   = true
}