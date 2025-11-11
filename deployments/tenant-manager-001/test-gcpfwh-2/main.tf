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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Configure the Google Cloud provider.
# The 'project' attribute is omitted as per instructions, it will be inferred from the environment.
provider "google" {
  region = var.region
}

# --- Terraform Variables ---

# Variable for the virtual machine instance name.
variable "instance_name" {
  type        = string
  default     = "test-gcpfwh-2"
  description = "Name of the virtual machine instance."
}

# Variable for the Google Cloud region.
variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region where resources will be deployed."
}

# Variable for the virtual machine size/machine type.
variable "vm_size" {
  type        = string
  default     = "e2-micro"
  description = "Machine type for the virtual machine."
}

# Variable for the tenant identifier.
variable "tenant_id" {
  type        = string
  default     = "tenant-manager-001"
  description = "Unique identifier for the tenant, used in resource naming."
}

# Variable for the operating system type (Linux or Windows).
variable "os_type" {
  type        = string
  default     = "Linux"
  description = "Operating system type (Linux or Windows)."
}

# Variable for the custom startup script to run on the instance.
variable "custom_script" {
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to run on instance startup (user data)."
}

# --- Data Sources ---

# Data source to retrieve the current GCP project ID.
data "google_project" "project" {}

# Data source to read the tenant VPC network.
# This depends on the 'null_resource.vpc_provisioner' to ensure the VPC is created before being read.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = data.google_project.project.project_id
  depends_on = [null_resource.vpc_provisioner]
}

# --- Random Resources ---

# Generates a random integer (2-254) to ensure a unique subnet CIDR block for each deployment.
# The 'keepers' block ensures that a new random number is generated if 'instance_name' changes.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  keepers = {
    instance_name = var.instance_name
  }
}

# --- SSH Key Generation (Linux Only) ---

# Generates a new SSH private key for instance access when deploying a Linux VM.
# The 'count' argument ensures this resource is only created if os_type is Linux.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'comment' argument is explicitly forbidden for this resource.
}

# --- Get-or-Create Shared Tenant Network Resources (Idempotent Provisioning) ---

# Null resource to idempotently create the tenant VPC network using gcloud CLI.
# It first attempts to describe the network; if it doesn't exist (indicated by '||'), it creates it.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command     = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
    interpreter = ["bash", "-c"]
  }
}

# Null resource to idempotently create a shared firewall rule for internal traffic within the tenant VPC.
# This rule allows all traffic from IP addresses in the 10.0.0.0/8 range.
resource "null_resource" "allow_internal_provisioner" {
  depends_on = [null_resource.vpc_provisioner] # Ensures VPC exists before creating rules.
  provisioner "local-exec" {
    command     = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
    interpreter = ["bash", "-c"]
  }
}

# Null resource to idempotently create a shared firewall rule for SSH access via Google's Identity-Aware Proxy (IAP).
# This allows SSH connections from IAP's IP ranges to instances tagged with 'ssh-via-iap'.
resource "null_resource" "allow_iap_ssh_provisioner" {
  depends_on = [null_resource.vpc_provisioner] # Ensures VPC exists before creating rules.
  provisioner "local-exec" {
    command     = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
    interpreter = ["bash", "-c"]
  }
}

# --- Networking Resources ---

# Create a unique subnetwork for this specific VM deployment within the tenant VPC.
# The IP range is dynamically generated using a random octet to avoid collisions.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  description   = "Subnet for instance ${var.instance_name} in region ${var.region}"
  depends_on    = [null_resource.vpc_provisioner] # Ensure VPC is ready before creating subnet.
}

# --- Virtual Machine Deployment ---

# The primary Google Compute Engine virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Deploys the instance into a specific zone within the region.
  # The 'project' attribute is omitted as per instructions.
  deletion_protection = false # Allows the instance to be deleted.

  # Boot disk configuration, using the specified custom image.
  boot_disk {
    initialize_params {
      # CRITICAL: Use the exact custom image name provided in the instructions.
      image = "ubuntu-22-04-19271224598"
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: The 'access_config' block is omitted to ensure no public IP address is assigned.
    # Connectivity will be managed via Google Cloud IAP.
  }

  # Service account configuration for the VM.
  # This provides the instance with permissions to interact with Google Cloud services.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Conditional metadata for SSH keys if the OS type is Linux.
  # This injects the public SSH key generated by 'tls_private_key' for root access.
  metadata = var.os_type == "Linux" ? {
    ssh-keys = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
  } : {}

  # Specifies a startup script to be executed when the instance starts.
  # This uses the 'custom_script' variable provided in the configuration.
  metadata_startup_script = var.custom_script

  # Tags applied to the instance for firewall rules and identification.
  # Tags are conditional based on the OS type to include IAP SSH or RDP/WinRM specific tags.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_iap_ssh_provisioner # Ensure IAP firewall rule is active before instance creation for Linux.
  ]
}

# --- Per-Instance Firewall Rules for Public Access ---

# Firewall rule to allow public SSH access to this specific instance (Linux only).
# The 'count' ensures this rule is only created if os_type is Linux.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Allows SSH from any public IP.
  target_tags   = ["allow-ssh-${var.instance_name}"]
  description   = "Allow public SSH access to ${var.instance_name} (Linux)"

  depends_on = [google_compute_instance.this_vm] # Depends on instance creation for tags to be available.
}

# Firewall rule to allow public RDP access to this specific instance (Windows only).
# The 'count' ensures this rule is only created if os_type is Windows.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"] # Allows RDP from any public IP.
  target_tags   = ["allow-rdp-${var.instance_name}"]
  description   = "Allow public RDP access to ${var.instance_name} (Windows)"

  depends_on = [google_compute_instance.this_vm] # Depends on instance creation for tags to be available.
}

# Firewall rule to allow public WinRM access to this specific instance (Windows only).
# The 'count' ensures this rule is only created if os_type is Windows.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  project = data.google_project.project.project_id

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # Allows WinRM over HTTP and HTTPS.
  }

  source_ranges = ["0.0.0.0/0"] # Allows WinRM from any public IP.
  target_tags   = ["allow-winrm-${var.instance_name}"]
  description   = "Allow public WinRM access to ${var.instance_name} (Windows)"

  depends_on = [google_compute_instance.this_vm] # Depends on instance creation for tags to be available.
}

# --- Outputs ---

# Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the VM."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the VM instance."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the network tags associated with the instance.
output "network_tags" {
  description = "Network tags applied to the VM instance."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key.
# This output is marked as sensitive to prevent it from being displayed in plaintext in logs.
# It is conditional, only showing the key if the VM is Linux.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (if Linux)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux VM"
  sensitive   = true
}