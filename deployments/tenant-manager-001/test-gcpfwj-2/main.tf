# main.tf

# Required providers block
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Google Cloud provider configuration
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Variables Block ---

# Name of the virtual machine instance
variable "instance_name" {
  description = "Name of the VM instance."
  type        = string
  default     = "test-gcpfwj-2"
}

# Google Cloud region for deployment
variable "region" {
  description = "Google Cloud region where the VM will be deployed."
  type        = string
  default     = "us-central1"
}

# Google Cloud zone for deployment
variable "zone" {
  description = "Google Cloud zone where the VM will be deployed. Defaulting to a common zone."
  type        = string
  default     = "us-central1-c" # Hardcoded default as zone is not in JSON config
}

# Size or machine type of the virtual machine
variable "vm_size" {
  description = "Machine type for the VM instance (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

# Unique identifier for the tenant
variable "tenant_id" {
  description = "Unique identifier for the tenant, used in naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

# Operating system type (Linux or Windows)
variable "os_type" {
  description = "Type of operating system (Linux or Windows)."
  type        = string
  default     = "Linux"
}

# Custom script to be executed on instance startup (user data)
variable "custom_script" {
  description = "Script to run on the instance upon startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Google Cloud Project ID
variable "project_id" {
  description = "The Google Cloud Project ID where resources will be deployed."
  type        = string
  default     = "umos-ab24d"
}

# --- Resources Block ---

# Generate an SSH key pair for Linux instances
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- GCP Networking and Tenant Isolation (Get-or-Create Pattern) ---

# Provisioner to get or create the tenant VPC network
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
  }

  provisioner "local-exec" {
    # Check if VPC exists; if not, create it with custom subnet mode
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant VPC network details after it's provisioned
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
  # Ensure this data source runs only after the VPC is guaranteed to exist
  depends_on = [null_resource.vpc_provisioner]
}

# Provisioner to get or create the shared internal traffic firewall rule
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
  }
  # Ensure the VPC data is available before running gcloud commands that use its name
  depends_on = [data.google_compute_network.tenant_vpc]

  provisioner "local-exec" {
    # Check if firewall rule exists; if not, create it
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
}

# Provisioner to get or create the shared IAP SSH firewall rule
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = var.project_id
  }
  # Ensure the VPC data is available before running gcloud commands that use its name
  depends_on = [data.google_compute_network.tenant_vpc]

  provisioner "local-exec" {
    # Check if firewall rule exists; if not, create it
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
}

# Generate a random integer for a unique subnet IP range octet
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  keepers = {
    instance_name = var.instance_name # Ensures a new random number if instance_name changes
  }
}

# Create a unique subnetwork for this deployment within the tenant VPC
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  project       = var.project_id
  # Explicitly depend on the VPC being ready and its data loaded
  depends_on = [
    data.google_compute_network.tenant_vpc,
    null_resource.vpc_provisioner
  ]
}

# Create per-instance firewall rule to allow public SSH access (Linux only)
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
  description   = "Allow public SSH access to ${var.instance_name} from anywhere."
}

# Create per-instance firewall rule to allow public RDP access (Windows only)
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
  description   = "Allow public RDP access to ${var.instance_name} from anywhere."
}

# Create per-instance firewall rule to allow public WinRM access (Windows only)
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
  description   = "Allow public WinRM access to ${var.instance_name} from anywhere."
}

# Virtual Machine Instance Deployment
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  project      = var.project_id
  zone         = var.zone
  machine_type = var.vm_size

  # Use the specified custom image name for the boot disk
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network configuration, including association with the unique subnet and a public IP
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      // An ephemeral public IP address is assigned here for external connectivity
    }
  }

  # Service account for the instance with cloud-platform scopes
  service_account {
    scopes = ["cloud-platform"]
  }

  # Tags for firewall rules. IAP tag for Linux, specific public access tags otherwise.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Startup script (user data) for instance initialization
  metadata_startup_script = var.custom_script

  # SSH keys for Linux instances are added via metadata
  metadata = var.os_type == "Linux" ? {
    "ssh-keys" = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
  } : {}

  # Disable deletion protection to allow easier teardown of the instance
  deletion_protection = false

  # Explicit dependencies to ensure networking resources are ready before the instance
  depends_on = [
    google_compute_subnetwork.this_subnet,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm
  ]
}

# --- Outputs Block ---

# Expose the private IP address of the virtual machine
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Expose the public IP address of the virtual machine
output "public_ip" {
  description = "The public IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

# Expose the cloud provider's native instance ID
output "instance_id" {
  description = "The unique instance ID assigned by Google Cloud."
  value       = google_compute_instance.this_vm.instance_id
}

# Expose the network tags associated with the instance
output "network_tags" {
  description = "List of network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

# Expose the generated private SSH key (sensitive)
output "private_ssh_key" {
  description = "The private SSH key (PEM format) generated for the VM."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not applicable for Windows OS"
  sensitive   = true
}