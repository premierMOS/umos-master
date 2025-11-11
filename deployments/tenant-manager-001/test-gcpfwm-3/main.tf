# Required providers
terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "~> 5.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Google Cloud Provider Configuration
# The project ID and region are explicitly set using variables.
provider "google" {
  project = var.project_id
  region  = var.region
}

# Input Variables
# Declare variables for key configuration values from the JSON.
# Each variable MUST include a 'default' value set directly from the provided configuration.
variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwm-3"
}

variable "region" {
  description = "GCP region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used in resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type (Linux or Windows)."
  type        = string
  default     = "Linux" # Derived from os.type in JSON
}

variable "custom_script" {
  description = "Custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "project_id" {
  description = "The GCP project ID where resources will be deployed."
  type        = string
  default     = "umos-ab24d" # Derived from gcpDefaultProjectId in JSON
}

# Random integers for generating a unique subnet CIDR range
# The 'keepers' block ensures the random value is regenerated only if instance_name changes,
# providing idempotency for unique subnet creation per instance.
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

# --- GCP Tenant Networking (Get-or-Create Pattern) ---
# This section ensures that shared tenant VPC and global firewall rules exist or are created idempotently
# using gcloud CLI commands within null_resource blocks.

# 1. Get-or-Create Tenant VPC Network
# This null_resource executes a local gcloud command to describe the VPC.
# If the describe command fails (VPC does not exist), it proceeds to create the VPC.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = var.project_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || \
      gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'
    EOT
  }
}

# Data source to read the provisioned tenant VPC network.
# Explicitly depends on the null_resource to ensure the VPC is guaranteed to exist before Terraform tries to read it.
data "google_compute_network" "tenant_vpc" {
  name    = "pmos-tenant-${var.tenant_id}-vpc"
  project = var.project_id
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

# 2. Get-or-Create Shared Firewall Rules
# Internal traffic rule: Allows all traffic within the 10.0.0.0/8 private IP range.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = var.project_id
    vpc_name = data.google_compute_network.tenant_vpc.name # Implicit dependency on data.google_compute_network.tenant_vpc
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || \
      gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8 --description='Allow all internal tenant traffic'
    EOT
  }
}

# IAP SSH rule: Allows SSH access from Google's IAP (Identity-Aware Proxy) IP ranges.
# This rule targets instances with the 'ssh-via-iap' network tag.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
    project_id = var.project_id
    vpc_name = data.google_compute_network.tenant_vpc.name # Implicit dependency on data.google_compute_network.tenant_vpc
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || \
      gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap --description='Allow SSH from IAP for Linux instances'
    EOT
  }
}

# 3. Create a Unique Subnet for this deployment
# A new subnet is created for each deployment to ensure isolation and prevent IP collisions.
resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  # Dynamically constructed IP CIDR range using random integers for uniqueness.
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  description   = "Subnet for instance ${var.instance_name} in tenant ${var.tenant_id} VPC"

  depends_on = [
    null_resource.vpc_provisioner # Ensure VPC is created before creating the subnet
  ]
}

# --- SSH Key Pair Generation (for Linux instances) ---
# Generates a new SSH key pair using the TLS provider.
# This resource is created only if the OS type is Linux.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0 # Conditional creation
  algorithm = "RSA"
  rsa_bits  = 2048
  # The 'comment' argument is forbidden as it is not supported by tls_private_key.
}

# --- Per-Instance Firewall Rules ---
# These rules provide specific public access to *this* instance based on its OS type and instance-specific tags.

# Public SSH rule for Linux instances. Allows SSH from any IP.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0 # Conditional creation for Linux
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"] # Targets a unique tag for this instance
  description = "Allow SSH to instance ${var.instance_name} from anywhere."

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on = [
    null_resource.vpc_provisioner # Ensure VPC is ready
  ]
}

# Public RDP rule for Windows instances. Allows RDP from any IP.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0 # Conditional creation for Windows
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"] # Targets a unique tag for this instance
  description = "Allow RDP to instance ${var.instance_name} from anywhere."

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on = [
    null_resource.vpc_provisioner # Ensure VPC is ready
  ]
}

# Public WinRM rule for Windows instances. Allows WinRM from any IP.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0 # Conditional creation for Windows
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"] # Targets a unique tag for this instance
  description = "Allow WinRM to instance ${var.instance_name} from anywhere."

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on = [
    null_resource.vpc_provisioner # Ensure VPC is ready
  ]
}


# --- Virtual Machine Deployment ---
# The primary compute resource for the virtual machine instance.
resource "google_compute_instance" "this_vm" {
  project         = var.project_id
  name            = var.instance_name
  machine_type    = var.vm_size
  # Using a default zone within the region. Can be made variable if specific zone control is needed.
  zone            = "${var.region}-c"
  deletion_protection = false # Set to false as per instruction

  # Boot disk configuration, using the specified custom image name.
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME: The exact and complete cloud image name provided in the instructions.
      image = "ubuntu-22-04-19271224598"
      size = 50 # Default disk size, can be made variable
    }
  }

  # Network interface configuration.
  # The instance is deployed into the unique subnet created for this deployment.
  # An 'access_config {}' block is required to assign an ephemeral public IP address.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      // Ephemeral public IP is assigned here.
    }
  }

  # Service account configuration.
  # Scopes are required for the instance to interact with other GCP services.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Instance tags for applying firewall rules.
  # Tags are conditional based on the OS type.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata block for startup script and SSH keys (for Linux instances).
  # All metadata, including startup scripts and SSH keys, MUST be placed inside a single 'metadata' map.
  metadata = {
    # Custom script to be run on instance startup.
    # GCP uses the 'startup-script' metadata key for this purpose.
    startup-script = var.custom_script

    # SSH key for Linux instances.
    # The 'ssh-keys' metadata entry is conditionally added for Linux instances.
    # Terraform correctly handles accessing 'tls_private_key.admin_ssh[0]' even if its count is 0.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # Explicit dependencies for conditional resources.
  # Terraform will correctly handle cases where a resource's count is zero (e.g., firewall rules for the wrong OS).
  # This ensures that all necessary networking components and SSH keys are in place before the VM is provisioned.
  depends_on = [
    google_compute_subnetwork.this_subnet,          # Depends on the subnet being created
    null_resource.allow_internal_provisioner,       # Depends on shared internal firewall rule
    null_resource.allow_iap_ssh_provisioner,        # Depends on shared IAP SSH firewall rule
    google_compute_firewall.allow_public_ssh,       # Depends on public SSH rule (if Linux)
    google_compute_firewall.allow_public_rdp,       # Depends on public RDP rule (if Windows)
    google_compute_firewall.allow_public_winrm,     # Depends on public WinRM rule (if Windows)
    tls_private_key.admin_ssh,                      # Depends on SSH key generation (if Linux)
  ]
}

# --- Outputs ---
# Exposes key information about the deployed virtual machine and associated resources.

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "public_ip" {
  description = "The public IP address of the virtual machine (if assigned)."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
}

output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "Network tags applied to the instance."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The generated private SSH key for Linux instances. Keep this secure!"
  # Conditionally output the private key for Linux, otherwise indicate N/A.
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux VM"
  sensitive   = true # CRITICAL: Mark as sensitive to prevent logging of private key.
}