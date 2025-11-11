# This Terraform HCL script deploys a virtual machine on Google Cloud Platform.
# It adheres to secure and private cloud infrastructure as code best practices,
# including tenant isolation, idempotent resource creation, and SSH key management.

# ---------------------------------------------------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------------------------------------------------

# Configure the Google Cloud provider.
# The 'project' attribute is intentionally omitted here and from resources as per critical instructions.
provider "google" {}

# Configure the TLS provider for generating SSH key pairs.
provider "tls" {}

# Configure the Random provider for generating unique subnet octets.
provider "random" {}

# ---------------------------------------------------------------------------------------------------------------------
# Input Variables
# ---------------------------------------------------------------------------------------------------------------------

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwb-1"
}

variable "region" {
  description = "The GCP region to deploy the VM in."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type for the VM instance."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming to ensure isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux" # Sourced from JSON: os.type
}

variable "custom_script" {
  description = "A custom script to run on instance startup via metadata_startup_script."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n" # Sourced from JSON: platform.customScript
}

variable "gcp_image_name" {
  description = "The exact custom image name for the VM. CRITICAL: DO NOT CHANGE - provided by instruction."
  type        = string
  default     = "ubuntu-22-04-19271224598" # CRITICAL instruction specified this exact image name.
}

# ---------------------------------------------------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------------------------------------------------

# Retrieves the current Google Cloud project ID.
# This is used for constructing gcloud commands for idempotent resource provisioning.
data "google_project" "project" {}

# ---------------------------------------------------------------------------------------------------------------------
# Tenant-Level Shared Networking Resources (Idempotent Get-or-Create Pattern)
# These resources are shared across all deployments for a given tenant.
# ---------------------------------------------------------------------------------------------------------------------

# null_resource to ensure the tenant-specific VPC network exists.
# It attempts to describe the network; if not found, it creates it using gcloud CLI.
resource "null_resource" "vpc_provisioner" {
  triggers = {
    tenant_id  = var.tenant_id
    project_id = data.google_project.project.project_id
  }

  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the tenant VPC network configuration after ensuring its existence.
# 'depends_on' ensures this block runs only after the 'vpc_provisioner' null_resource completes.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# null_resource to ensure the shared internal firewall rule for the tenant VPC exists.
# This rule allows all internal traffic within the 10.0.0.0/8 CIDR block.
resource "null_resource" "allow_internal_provisioner" {
  triggers = {
    tenant_id    = var.tenant_id
    project_id   = data.google_project.project.project_id
    network_name = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# null_resource to ensure the shared IAP (Identity-Aware Proxy) SSH firewall rule exists.
# This rule allows SSH access via IAP to instances tagged 'ssh-via-iap'.
resource "null_resource" "allow_iap_ssh_provisioner" {
  triggers = {
    tenant_id    = var.tenant_id
    project_id   = data.google_project.project.project_id
    network_name = data.google_compute_network.tenant_vpc.name
  }

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}


# ---------------------------------------------------------------------------------------------------------------------
# Per-Instance Networking Resources
# These resources are unique to this specific virtual machine deployment.
# ---------------------------------------------------------------------------------------------------------------------

# Generates a random integer (2-254) to create a unique third octet for the subnet's CIDR range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Creates a unique subnetwork for this deployment within the shared tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on = [
    data.google_compute_network.tenant_vpc # Ensure the tenant VPC is available
  ]
}

# Creates a firewall rule to allow public SSH access (TCP port 22) for Linux VMs.
# This rule targets instances with a specific tag unique to this deployment.
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create for Linux VMs

  name          = "pmos-instance-${var.instance_name}-allow-ssh"
  network       = data.google_compute_network.tenant_vpc.self_link
  description   = "Allow public SSH (TCP 22) access to ${var.instance_name}"
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  depends_on = [data.google_compute_network.tenant_vpc, google_compute_subnetwork.this_subnet]
}

# Creates a firewall rule to allow public RDP access (TCP port 3389) for Windows VMs.
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create for Windows VMs

  name          = "pmos-instance-${var.instance_name}-allow-rdp"
  network       = data.google_compute_network.tenant_vpc.self_link
  description   = "Allow public RDP (TCP 3389) access to ${var.instance_name}"
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-rdp-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
  depends_on = [data.google_compute_network.tenant_vpc, google_compute_subnetwork.this_subnet]
}

# Creates a firewall rule to allow public WinRM access (TCP ports 5985-5986) for Windows VMs.
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create for Windows VMs

  name          = "pmos-instance-${var.instance_name}-allow-winrm"
  network       = data.google_compute_network.tenant_vpc.self_link
  description   = "Allow public WinRM (TCP 5985-5986) access to ${var.instance_name}"
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }
  depends_on = [data.google_compute_network.tenant_vpc, google_compute_subnetwork.this_subnet]
}

# ---------------------------------------------------------------------------------------------------------------------
# SSH Key Pair (for Linux deployments)
# ---------------------------------------------------------------------------------------------------------------------

# Generates a new RSA SSH private key.
# This resource is only created if the OS type is Linux.
resource "tls_private_key" "admin_ssh" {
  count = var.os_type == "Linux" ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
}

# ---------------------------------------------------------------------------------------------------------------------
# Virtual Machine Deployment
# ---------------------------------------------------------------------------------------------------------------------

# Deploys the Google Compute Engine virtual machine instance.
# The 'project' attribute is intentionally omitted as per critical instructions.
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Defaulting to zone 'a' within the region for simplicity
  deletion_protection = false # As per instruction

  # Boot disk configuration, using the specified custom image name.
  boot_disk {
    initialize_params {
      image = var.gcp_image_name
    }
  }

  # Network interface configuration.
  # Attached to the unique subnet and configured to assign an ephemeral public IP.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      # This empty block assigns an ephemeral public IP address to the instance.
    }
  }

  # Service account with necessary scopes for instance management.
  service_account {
    scopes = ["cloud-platform"] # Broad scope for demonstration; refine for production.
  }

  # Metadata for SSH keys (for Linux VMs) and startup script.
  metadata = {
    # For Linux, inject the generated public SSH key.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
    # Inject the custom script as a startup script.
    startup-script = var.custom_script
  }

  # Network tags for applying firewall rules.
  # Tags are conditional based on the OS type to allow appropriate access.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Explicit dependencies to ensure networking resources are fully provisioned before instance creation.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm,
  ]
}

# ---------------------------------------------------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------------------------------------------------

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "instance_id" {
  description = "The unique instance ID assigned by GCP."
  value       = google_compute_instance.this_vm.instance_id
}

output "network_tags" {
  description = "The network tags associated with the instance, used for firewall rules."
  value       = google_compute_instance.this_vm.tags
}

output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance (Linux only). Keep this secure!"
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux VM"
  sensitive   = true # Mark as sensitive to prevent display in plaintext logs
}