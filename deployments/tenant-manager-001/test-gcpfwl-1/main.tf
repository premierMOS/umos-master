# main.tf

# Configure the Google Cloud provider
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
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

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Variables Block ---
# Declares all necessary input variables with default values derived directly from the JSON configuration.
# This ensures the script is non-interactive and ready to deploy.

variable "instance_name" {
  type        = string
  description = "The name of the virtual machine instance."
  default     = "test-gcpfwl-1"
}

variable "region" {
  type        = string
  description = "The Google Cloud region where the VM and related resources will be deployed."
  default     = "us-central1"
}

variable "vm_size" {
  type        = string
  description = "The machine type (size) for the virtual machine."
  default     = "e2-micro"
}

variable "custom_script" {
  type        = string
  description = "A base64 encoded custom script to be executed on the VM instance at startup."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  type        = string
  description = "A unique identifier for the tenant, used for naming shared network resources."
  default     = "tenant-manager-001"
}

variable "os_type" {
  type        = string
  description = "The operating system type of the VM (e.g., Linux, Windows)."
  default     = "Linux"
}

variable "project_id" {
  type        = string
  description = "The Google Cloud Project ID where resources will be deployed."
  default     = "umos-ab24d"
}

# --- SSH Key Pair Generation (Linux only) ---
# Generates a new RSA SSH key pair for Linux instances.
# The private key is output as sensitive, and the public key is used for instance metadata.
resource "tls_private_key" "admin_ssh" {
  # This resource is created only if the OS type is Linux.
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Get-or-Create Tenant VPC Network (Idempotent via null_resource and gcloud CLI) ---
# This null_resource attempts to describe the tenant VPC network. If it doesn't exist,
# it creates it. This ensures the network is provisioned exactly once per tenant.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    # CRITICAL: Idempotent gcloud command to get or create the VPC network.
    # The '>/dev/null 2>&1' suppresses output, so '||' relies on exit code.
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }

  triggers = {
    # Triggers ensure the local-exec runs if these values change.
    tenant_vpc_name = "pmos-tenant-${var.tenant_id}-vpc"
    project_id      = var.project_id
  }
}

# Data source to read the existing or newly created tenant VPC network.
# CRITICAL: depends_on ensures this runs AFTER the null_resource completes.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# --- Get-or-Create Shared Firewall Rules (Idempotent via null_resource and gcloud CLI) ---
# These null_resources ensure essential shared firewall rules exist for the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    # Rule to allow all internal traffic within the 10.0.0.0/8 range.
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }

  triggers = {
    tenant_id    = var.tenant_id
    project_id   = var.project_id
    network_name = data.google_compute_network.tenant_vpc.name
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    # Rule to allow SSH access via Google Cloud IAP (Identity-Aware Proxy)
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }

  triggers = {
    tenant_id    = var.tenant_id
    project_id   = var.project_id
    network_name = data.google_compute_network.tenant_vpc.name
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- Unique Subnet Generation ---
# Generates random octets to create a unique IP CIDR range for the subnet,
# preventing collisions during concurrent deployments.
resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    # CRITICAL: Keeper ensures the random value is regenerated only if instance_name changes.
    instance_name = var.instance_name
  }
}

resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    # CRITICAL: Keeper ensures the random value is regenerated only if instance_name changes.
    instance_name = var.instance_name
  }
}

# Creates a new subnetwork dedicated to this VM deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  project       = var.project_id

  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# --- Virtual Machine Instance Deployment ---
# Deploys the primary virtual machine instance with specified configuration.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Using 'a' as default zone within the region
  project      = var.project_id

  # Boot disk configuration, using the specified custom image ID.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Specific custom image name.
      labels = {
        name = var.instance_name
      }
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: `access_config {}` assigns an ephemeral public IP for direct connectivity.
    access_config {}
  }

  # Service account for the instance with appropriate scopes.
  service_account {
    scopes = ["cloud-platform"] # Full access to GCP services for the instance.
  }

  # CRITICAL METADATA STRUCTURE: All metadata is passed in a single map.
  metadata = merge(
    {
      "startup-script" = var.custom_script # User data/startup script
    },
    # Conditionally add SSH keys for Linux instances.
    var.os_type == "Linux" ? { "ssh-keys" = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" } : {}
  )

  # Conditional network tags for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # CRITICAL: Deletion protection is set to false as per requirements.
  deletion_protection = false

  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_iap_ssh_provisioner,
    # Ensure SSH key is generated before attempting to use it in metadata.
    var.os_type == "Linux" ? tls_private_key.admin_ssh[0] : null
  ]
}

# --- Per-Instance Firewall Rules for Public Access ---
# These firewall rules provide public access based on the OS type.
# They are scoped to the specific instance via unique target tags.

# Allow public SSH access for Linux instances.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  project = var.project_id
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]
  description   = "Allow public SSH access to ${var.instance_name} (Linux)"

  depends_on = [
    data.google_compute_network.tenant_vpc,
    google_compute_instance.this_vm
  ]
}

# Allow public RDP access for Windows instances.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  project = var.project_id
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]
  description   = "Allow public RDP access to ${var.instance_name} (Windows)"

  depends_on = [
    data.google_compute_network.tenant_vpc,
    google_compute_instance.this_vm
  ]
}

# Allow public WinRM access for Windows instances.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  project = var.project_id
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
  description   = "Allow public WinRM access to ${var.instance_name} (Windows)"

  depends_on = [
    data.google_compute_network.tenant_vpc,
    google_compute_instance.this_vm
  ]
}

# --- Outputs Block ---
# Exposes key information about the deployed virtual machine.

output "private_ip" {
  description = "The private IP address of the deployed VM instance."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "public_ip" {
  description = "The public IP address of the deployed VM instance."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

output "instance_id" {
  description = "The unique Google Cloud instance ID of the VM."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags applied to the VM instance."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The generated private SSH key for Linux instances. Keep this secure!"
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "SSH key not generated for Windows OS"
  sensitive   = true # CRITICAL: Mark as sensitive to prevent showing in logs.
}