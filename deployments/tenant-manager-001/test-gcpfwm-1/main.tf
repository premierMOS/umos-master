# This script deploys a virtual machine on Google Cloud Platform.
# It uses Terraform to define the infrastructure as code,
# including networking, firewall rules, and the VM itself.

# --- Providers Configuration ---
# Configure the Google Cloud provider.
# The project ID is sourced from a variable.
provider "google" {
  project = var.project_id
  region  = var.region
}

# Configure the Random provider for unique resource naming and IP ranges.
# This is used for generating unique subnet CIDRs.
provider "random" {}

# --- Variables Declaration ---
# Declaring variables for key configuration values.
# Each variable includes a 'default' value directly from the provided JSON
# or based on critical instructions, preventing interactive prompts.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwm-1"
}

variable "region" {
  description = "The GCP region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone where the virtual machine will be deployed. Defaults to 'c' within the specified region."
  type        = string
  default     = "us-central1-c" # Derived from region: ${var.region}-c
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "A custom script to execute on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "project_id" {
  description = "The GCP project ID where resources will be deployed."
  type        = string
  default     = "umos-ab24d"
}

variable "image_name" {
  description = "The exact name of the custom image to use for the VM."
  type        = string
  default     = "ubuntu-22-04-19271224598"
}

# --- GCP Shared Tenant Resources (Get-or-Create with gcloud via null_resource) ---
# This section uses `null_resource` with `local-exec` to create shared tenant-level
# resources (VPC network and common firewall rules) using `gcloud CLI`.
# The commands are idempotent, ensuring the resources are created only if they don't exist.

# Resource to get or create the tenant-specific VPC network.
# This prevents "resource already exists" errors in concurrent deployments.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the provisioned tenant VPC network's details.
# Explicitly depends on the `vpc_provisioner` to ensure the network exists before reading.
data "google_compute_network" "tenant_vpc" {
  project = var.project_id
  name    = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [
    null_resource.vpc_provisioner
  ]
}

# Resource to get or create the shared firewall rule for internal traffic within the tenant VPC.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before trying to create a rule for it
  ]
}

# Resource to get or create the shared firewall rule for IAP (Identity-Aware Proxy) SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure VPC exists before trying to create a rule for it
  ]
}

# --- Unique Subnet Creation ---
# Generate random integers for the second and third octets of the subnet's IP CIDR range.
# The 'keepers' block ensures a new random number is generated only if the instance_name changes,
# making the subnet range stable for a given instance deployment.
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

# Create a new, unique subnetwork for this specific deployment.
resource "google_compute_subnetwork" "this_subnet" {
  project = var.project_id
  name    = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region  = var.region
  network = data.google_compute_network.tenant_vpc.self_link
  depends_on = [
    random_integer.subnet_octet_2,
    random_integer.subnet_octet_3,
    data.google_compute_network.tenant_vpc
  ]
}

# --- SSH Key Pair Generation (for Linux VMs) ---
# Generate a new SSH private/public key pair using the tls_private_key resource.
# This resource is conditionally created only if the OS type is Linux.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

# --- Virtual Machine Deployment ---
# Deploys the primary virtual machine instance on GCP.
resource "google_compute_instance" "this_vm" {
  project          = var.project_id
  name             = var.instance_name
  machine_type     = var.vm_size
  zone             = var.zone
  deletion_protection = false # As per instruction, ensure deletion protection is false.

  # Boot disk configuration, using the specified custom image.
  boot_disk {
    initialize_params {
      image = var.image_name
    }
  }

  # Network interface configuration, deploying into the unique subnet.
  # Includes an access_config block to assign an ephemeral public IP address.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      // Ephemeral public IP is assigned here.
    }
  }

  # Service account with broad scopes for common cloud operations.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Tags applied to the instance for network isolation and firewall rules.
  # Tags are conditional based on the OS type.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Metadata block for startup scripts and SSH keys.
  # All metadata is placed within a single map.
  metadata = {
    startup-script = var.custom_script
    # Conditionally add SSH keys for Linux instances.
    ssh-keys       = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # Explicit dependencies to ensure correct resource creation order.
  # Terraform will gracefully handle `count = 0` for resources in this list.
  depends_on = [
    tls_private_key.admin_ssh,             # Ensure SSH key is generated before being referenced in metadata
    google_compute_subnetwork.this_subnet, # Ensure subnet exists before instance is created in it
    null_resource.vpc_provisioner,         # Ensure VPC setup is complete
    null_resource.allow_internal_provisioner, # Ensure shared internal firewall is provisioned
    null_resource.allow_iap_ssh_provisioner # Ensure shared IAP SSH firewall is provisioned
  ]
}

# --- Per-Instance Firewall Rules ---
# These firewall rules provide specific public access for this instance,
# identified by unique target tags. They are conditionally created based on OS type.

# Firewall rule to allow public SSH access for Linux instances.
resource "google_compute_firewall" "allow_public_ssh" {
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

# Firewall rule to allow public RDP access for Windows instances.
resource "google_compute_firewall" "allow_public_rdp" {
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

# Firewall rule to allow public WinRM access for Windows instances.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  project = var.project_id
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # Standard WinRM ports
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]
  depends_on = [
    data.google_compute_network.tenant_vpc
  ]
}

# --- Outputs ---
# Provide key information about the deployed virtual machine.

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

output "network_tags" {
  description = "The network tags applied to the virtual machine instance."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The private SSH key for accessing Linux instances. Keep this secure!"
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A (Windows VM or SSH key not generated)"
  sensitive   = true
}