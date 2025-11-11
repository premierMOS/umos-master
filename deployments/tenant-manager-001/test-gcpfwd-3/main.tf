# This Terraform configuration deploys a virtual machine on Google Cloud Platform.
# It includes tenant isolation features, dynamic networking, and SSH key management.

# --- Providers Block ---
# Specifies the required providers and their versions.
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
# The 'project' attribute is intentionally omitted as per critical instructions
# to rely on ADC (Application Default Credentials) or environment variables.
provider "google" {
  region = var.region
}

# --- Variables Block ---
# Declares all key configuration values as Terraform variables with default values
# extracted directly from the provided JSON configuration.
# This ensures the script is non-interactive and ready to use.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-gcpfwd-3"
}

variable "region" {
  description = "The GCP region where the resources will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "The unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (Linux or Windows)."
  type        = string
  default     = "Linux" # Derived from os.type in JSON
}

variable "custom_script" {
  description = "A base64-encoded custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Data Sources Block ---
# Data sources are used to fetch information about existing resources.

# Get the current Google Cloud project ID. Required for gcloud commands.
data "google_project" "project" {}

# Data source to read the tenant VPC network, ensuring it exists after the null_resource.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner] # Explicit dependency on the VPC creation
}

# --- Resource Blocks ---
# These blocks define the infrastructure resources to be created.

# --- Tenant-Level Networking (Get-or-Create with null_resource and gcloud CLI) ---

# Provisioner to get or create the shared tenant VPC network.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
  # This makes the null_resource depend on itself changing, ensuring it always runs
  # if any of its implicit dependencies (like project ID) change.
  # For get-or-create, we want it to run always.
  triggers = {
    always_run = timestamp()
  }
}

# Provisioner to get or create the shared firewall rule for internal traffic.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating firewall rules.
  triggers = {
    always_run = timestamp()
  }
}

# Provisioner to get or create the shared firewall rule for IAP SSH access.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating firewall rules.
  triggers = {
    always_run = timestamp()
  }
}

# Generate a random integer for a unique subnet octet.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a unique subnetwork for this specific deployment within the tenant VPC.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [null_resource.vpc_provisioner] # Ensure VPC exists before creating subnet.
}

# --- Instance-Level Firewall Rules for Public Access ---

# Firewall rule to allow public SSH access specifically for this instance (Linux only).
resource "google_compute_firewall" "allow_public_ssh" {
  count   = var.os_type == "Linux" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-ssh-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on = [google_compute_subnetwork.this_subnet] # Ensure networking exists.
}

# Firewall rule to allow public RDP access specifically for this instance (Windows only).
resource "google_compute_firewall" "allow_public_rdp" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-rdp-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on = [google_compute_subnetwork.this_subnet] # Ensure networking exists.
}

# Firewall rule to allow public WinRM access specifically for this instance (Windows only).
resource "google_compute_firewall" "allow_public_winrm" {
  count   = var.os_type == "Windows" ? 1 : 0
  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link
  target_tags = ["allow-winrm-${var.instance_name}"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"]
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on = [google_compute_subnetwork.this_subnet] # Ensure networking exists.
}

# --- SSH Key Pair Generation (for Linux instances) ---

# Generates a new RSA private key for SSH access.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: Do NOT include 'comment' here as per instruction.
}

# --- Virtual Machine Instance ---

# The primary compute resource: a Google Compute Engine instance.
resource "google_compute_instance" "this_vm" {
  name                      = var.instance_name
  machine_type              = var.vm_size
  zone                      = "${var.region}-a" # Defaulting to zone 'a' within the specified region.
  deletion_protection       = false             # As per critical instructions.
  # The 'project' attribute is omitted here, relying on the provider's configuration.

  # Conditional tags based on OS type for firewall rules and IAP.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  boot_disk {
    initialize_params {
      # CRITICAL: Use the exact specified custom image name.
      image = "ubuntu-22-04-19271224598"
      size  = 50 # Default disk size.
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL: This empty block assigns an ephemeral public IP, required for SSM.
    access_config {
    }
  }

  # Service account with Cloud Platform scope.
  service_account {
    scopes = ["cloud-platform"]
  }

  # Metadata for startup script and SSH keys (for Linux).
  metadata = {
    startup-script = var.custom_script # User data/custom script
    # SSH keys for Linux instances.
    ssh-keys = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # Dependency on instance-level firewall rules to ensure they are created before instance.
  depends_on = [
    google_compute_firewall.allow_public_ssh,
    google_compute_firewall.allow_public_rdp,
    google_compute_firewall.allow_public_winrm
  ]

  # Optional: Define scheduling options if needed.
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
  }
}

# --- Outputs Block ---
# Defines the output values that will be displayed after Terraform applies the configuration.

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
  description = "The private SSH key generated for accessing the Linux instance. Keep this secure!"
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A (Windows instance)"
  sensitive   = true # Mark this output as sensitive to prevent it from being shown in plain text.
}