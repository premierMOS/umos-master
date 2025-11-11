# main.tf

# Configure the Google Cloud provider
# The 'project' attribute is intentionally omitted as per instructions.
provider "google" {
  region = var.region
  # The 'project' attribute is intentionally omitted to allow for dynamic project resolution,
  # typically through environment variables or gcloud configuration.
}

# Configure the TLS provider for SSH key generation
provider "tls" {}

# Configure the Random provider for unique subnet IP ranges
provider "random" {}

# --- Input Variables ---

variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpfwg-1"
}

variable "region" {
  description = "GCP region where resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone where the VM will be deployed. Derived from region if not explicitly set."
  type        = string
  default     = "us-central1-a" # Default zone for us-central1
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
  default     = "Linux" # From os.type in JSON
}

variable "custom_script" {
  description = "Base64 encoded custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Data Sources ---

# Data source to retrieve the current Google Cloud project ID.
# This is crucial for gcloud commands in the null_resources.
data "google_project" "project" {}

# --- Tenant-Shared Networking (Get-or-Create Idempotent Logic) ---

# Provisioner to get or create the tenant-specific VPC network.
# Uses 'gcloud' CLI with a 'null_resource' to ensure idempotency.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id = var.tenant_id
  }

  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant-specific VPC network after it's ensured to exist.
# Depends on 'vpc_provisioner' to ensure the network exists before Terraform tries to read it.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Provisioner to get or create a shared firewall rule for internal traffic within the tenant VPC.
# This ensures all VMs within the VPC can communicate on all ports and protocols.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id     = var.tenant_id
    network_self_link = data.google_compute_network.tenant_vpc.self_link
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists
}

# Provisioner to get or create a shared firewall rule for IAP SSH access.
# This rule allows SSH access via Google Cloud's Identity-Aware Proxy.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id     = var.tenant_id
    network_self_link = data.google_compute_network.tenant_vpc.self_link
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists
}

# --- Unique Subnet for this Deployment ---

# Generates a random integer for the second octet of the subnet IP range.
# This helps ensure unique subnets for concurrent deployments within the same VPC.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Creates a unique subnetwork for this specific VM deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link

  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating subnet
}

# --- SSH Key Pair Generation (for Linux VMs) ---

# Generates a new RSA private key for SSH access.
# The `comment` argument is explicitly forbidden.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

# --- Virtual Machine Deployment ---

# Deploys a Google Compute Engine virtual machine instance.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = var.zone
  deletion_protection = false # As per instruction

  # Apply dynamic tags based on OS type for per-instance firewall rules and IAP access.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Boot disk configuration, using the specified custom image name.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Use the exact specified image name
    }
  }

  # Network interface configuration, attached to the unique subnet.
  # CRITICAL: No 'access_config' block is present to avoid assigning a public IP,
  # relying on IAP for connectivity.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # NO 'access_config' block should be present here as per instructions.
  }

  # Service account with cloud-platform scope for various GCP service access.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Metadata for SSH keys (Linux) and startup scripts.
  metadata = merge(
    var.os_type == "Linux" ? {
      # Add the public SSH key for the 'packer' user.
      ssh-keys = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}"
    } : {},
    var.custom_script != "" ? {
      # Pass the custom script as a startup script.
      metadata_startup_script = var.custom_script
    } : {}
  )

  # Explicitly depend on shared firewall rules to ensure they are created first.
  depends_on = [
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner
  ]
}

# --- Per-Instance Firewall Rules for Public Access (Conditional) ---

# Firewall rule to allow public SSH access (TCP 22) to this specific Linux instance.
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
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

# Firewall rule to allow public RDP access (TCP 3389) to this specific Windows instance.
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
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

# Firewall rule to allow public WinRM access (TCP 5985-5986) to this specific Windows instance.
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
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

output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "Network tags applied to the instance."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The private SSH key generated for accessing the instance."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A (Windows OS)"
  sensitive   = true
}

output "ssh_command_linux" {
  description = "Suggested SSH command for Linux instances via IAP."
  value = var.os_type == "Linux" ? "gcloud compute ssh --zone=${var.zone} ${var.instance_name} --tunnel-through-iap --project=${data.google_project.project.project_id} --ssh-key-file=<path_to_private_key>" : "N/A (Windows OS)"
  sensitive = true
}

output "gcp_instance_name" {
  description = "The name of the created GCP instance."
  value       = google_compute_instance.this_vm.name
}

output "gcp_zone" {
  description = "The zone where the GCP instance is deployed."
  value       = google_compute_instance.this_vm.zone
}

output "subnet_id" {
  description = "The ID of the created subnetwork."
  value       = google_compute_subnetwork.this_subnet.id
}