# Required providers for Google Cloud, TLS key generation, local command execution, and random number generation.
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Specify a compatible version
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Specify a compatible version
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0" # Specify a compatible version
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # Specify a compatible version
    }
  }
}

# Google Cloud Platform provider configuration.
# The 'project' attribute is omitted here as per instructions, it will be inferred from the environment (e.g., gcloud config).
provider "google" {
  region = var.region
}

# Declare Terraform variables for key configuration values, with default values from the JSON.
# This ensures the script is non-interactive and ready to use.

variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpfw-3"
}

variable "region" {
  description = "GCP region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used in resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type of the VM (Linux or Windows)."
  type        = string
  default     = "Linux" # Derived from os.type in the JSON configuration
}

variable "custom_script" {
  description = "Optional custom script (user data) to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "image_name" {
  description = "The exact cloud image name to use for the VM's boot disk."
  type        = string
  # CRITICAL IMAGE NAME INSTRUCTION: Use the specified cloud image name.
  default     = "ubuntu-22-04-19271224598"
}


# --- GCP Shared Tenant Network Resources (Get-or-Create Idempotent Pattern) ---

# Data source to retrieve the current GCP project ID, essential for gcloud commands.
data "google_project" "project" {}

# Null resource to provision or verify the existence of the tenant VPC network.
# Uses 'local-exec' to run gcloud CLI commands, ensuring the VPC is created only if it doesn't exist.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    # Check if network exists; if not, create it. Output is redirected to /dev/null.
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the details of the tenant VPC network.
# Explicit dependency on `vpc_provisioner` ensures the VPC is available before this data source attempts to read it.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Null resource to get-or-create a shared firewall rule allowing internal (10.0.0.0/8) traffic within the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Null resource to get-or-create a shared firewall rule for IAP (Identity-Aware Proxy) SSH access.
# This allows secure SSH connections from Google's IAP range to instances tagged 'ssh-via-iap'.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# --- GCP Unique Subnet for this Deployment ---

# Generates a random integer between 2 and 254 to create a unique third octet for the subnet's IP range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Creates a new, unique subnetwork specifically for this virtual machine deployment.
# It is placed within the shared tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # Dynamically generated IP range
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  private_ip_google_access = true # Enable Private Google Access for managed services connectivity
}

# --- SSH Key Pair Generation (Conditional for Linux Deployments) ---

# Generates a new RSA private key locally.
# The 'count' meta-argument ensures this resource is created only if os_type is "Linux".
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0 # Only create for Linux VMs
  algorithm = "RSA"
  rsa_bits  = 2048
}

# --- Virtual Machine Deployment ---

# Primary compute resource: Google Compute Engine virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-c" # Deploying to zone 'c' within the specified region.
  deletion_protection = false # As per instruction, enable deletion protection if needed.

  # CRITICAL: The 'project' attribute is omitted as per instructions.

  # Boot disk configuration, using the specified custom image.
  boot_disk {
    initialize_params {
      image = var.image_name # CRITICAL IMAGE NAME INSTRUCTION: Using the exact custom image name
    }
  }

  # Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: This empty block assigns an ephemeral public IP address to the instance.
    access_config {
      # This block MUST remain empty to assign an ephemeral public IP.
    }
  }

  # Service account configuration with scopes for API access.
  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"] # Grants broad access to Google Cloud APIs.
  }

  # Conditional network tags applied to the instance for firewall rules.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata for startup scripts and SSH keys.
  metadata = merge(
    var.custom_script != "" ? { startup-script = var.custom_script } : {}, # Pass custom script if provided
    var.os_type == "Linux" ? { ssh-keys = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" } : {} # Add SSH public key for Linux
  )
}

# --- Per-Instance Firewall Rules for Public Access (Conditional by OS Type) ---

# Firewall rule to allow public SSH access to this specific Linux instance.
# The 'count' meta-argument makes this resource conditional.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"] # Targets the instance with this tag
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"] # Allow from any IP
  description = "Allow public SSH access to ${var.instance_name} (Linux)"
}

# Firewall rule to allow public RDP access to this specific Windows instance.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"] # Targets the instance with this tag
  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
  source_ranges = ["0.0.0.0/0"] # Allow from any IP
  description = "Allow public RDP access to ${var.instance_name} (Windows)"
}

# Firewall rule to allow public WinRM access to this specific Windows instance.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"] # Targets the instance with this tag
  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # HTTP and HTTPS WinRM ports
  }
  source_ranges = ["0.0.0.0/0"] # Allow from any IP
  description = "Allow public WinRM access to ${var.instance_name} (Windows)"
}

# --- Outputs ---

output "private_ip" {
  description = "The private IP address of the created virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID of the virtual machine."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags applied to the instance, used for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key, marked as sensitive to prevent display in logs.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (only for Linux VMs)."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux VM"
  sensitive   = true
}