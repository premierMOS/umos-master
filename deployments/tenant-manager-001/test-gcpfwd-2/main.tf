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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# The 'project' attribute is intentionally omitted here to pick it up from the environment (e.g., gcloud config or GOOGLE_CLOUD_PROJECT env var)
provider "google" {
  region = var.region
}

# Terraform Variables for key configuration values
variable "instance_name" {
  type    = string
  default = "test-gcpfwd-2"
  # Description: The desired name for the virtual machine instance.
}

variable "region" {
  type    = string
  default = "us-central1"
  # Description: The GCP region where the VM will be deployed.
}

variable "vm_size" {
  type    = string
  default = "e2-micro"
  # Description: The machine type (size) for the virtual machine.
}

variable "tenant_id" {
  type    = string
  default = "tenant-manager-001"
  # Description: The ID of the tenant for resource naming and isolation.
}

variable "os_type" {
  type    = string
  default = "Linux"
  # Description: The operating system type of the VM (e.g., "Linux" or "Windows").
}

variable "custom_script" {
  type    = string
  default = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  # Description: An optional custom script to run on instance startup.
}

# Data source to retrieve the current GCP project ID, required for gcloud commands.
data "google_project" "project" {}

# Generate a random integer for creating a unique subnet IP range octet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Get-or-Create Tenant VPC Network using a null_resource with local-exec provisioner.
# This ensures the VPC exists before other resources try to use it, and is idempotent.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = data.google_project.project.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
    interpreter = ["bash", "-c"]
  }
}

# Data source to read the provisioned or existing tenant VPC.
# Explicitly depends on the null_resource to ensure creation order.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  # The 'project' attribute is intentionally omitted here to pick it up from the environment
  depends_on = [null_resource.vpc_provisioner]
}

# Get-or-Create Shared Firewall Rule for internal traffic.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = data.google_project.project.project_id
    vpc_name = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
    interpreter = ["bash", "-c"]
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Get-or-Create Shared Firewall Rule for IAP SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = data.google_project.project.project_id
    vpc_name = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
    interpreter = ["bash", "-c"]
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Create a unique subnetwork for this deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  # The 'project' attribute is intentionally omitted here
}

# Generate an SSH key pair for Linux instances.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Deploy the virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Assuming a default zone within the region, adjust if needed
  deletion_protection = false

  # The 'project' attribute is intentionally omitted here to pick it up from the environment

  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Exact custom image name
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: Empty access_config block assigns an ephemeral public IP. DO NOT MOVE IT.
    access_config {}
  }

  # Service account with cloud-platform scope for general access, e.g., to Storage.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Metadata for SSH key injection and startup script execution.
  metadata = {
    ssh-keys       = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
    startup-script = var.custom_script
  }

  # Apply network tags conditionally based on OS type for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Depends on the shared firewall rules to ensure they are present before the instance attempts to use them.
  depends_on = [
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# Per-instance firewall rule for public SSH access (Linux only).
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  # The 'project' attribute is intentionally omitted here

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Public internet access
  target_tags   = ["allow-ssh-${var.instance_name}"]
  description   = "Allow public SSH access to ${var.instance_name}"
}

# Per-instance firewall rule for public RDP access (Windows only).
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  # The 'project' attribute is intentionally omitted here

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"] # Public internet access
  target_tags   = ["allow-rdp-${var.instance_name}"]
  description   = "Allow public RDP access to ${var.instance_name}"
}

# Per-instance firewall rule for public WinRM access (Windows only).
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  # The 'project' attribute is intentionally omitted here

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"] # Public internet access
  target_tags   = ["allow-winrm-${var.instance_name}"]
  description   = "Allow public WinRM access to ${var.instance_name}"
}


# Outputs
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags applied to the instance."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The private SSH key generated for accessing the instance."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Only generated for Linux VMs"
  sensitive   = true
}