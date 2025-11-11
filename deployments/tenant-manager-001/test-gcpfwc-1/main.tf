# This Terraform script deploys a virtual machine on Google Cloud Platform,
# adhering to strict security, tenant isolation, and management requirements.

# Configure Terraform providers
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Specify a compatible version range for Google Cloud provider
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Specify a compatible version range for TLS provider
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0" # Specify a compatible version range for Random provider
    }
  }
}

# Configure the Google Cloud provider.
# CRITICAL: The 'project' attribute is intentionally omitted here and from the instance resource
# to ensure it's picked up from the environment (e.g., gcloud config get-value project).
provider "google" {
  region = var.region
}

# Declare Terraform variables for key configuration values.
# CRITICAL VARIABLE INSTRUCTION: Each variable MUST include a 'default' value from the JSON.
variable "instance_name" {
  description = "The desired name for the virtual machine instance."
  type        = string
  default     = "test-gcpfwc-1"
}

variable "region" {
  description = "The GCP region where the virtual machine will be deployed."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used in naming shared resources."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (e.g., 'Linux' or 'Windows') of the VM."
  type        = string
  default     = "Linux" # Derived from os.type in the JSON
}

variable "custom_script" {
  description = "A user data script to be executed on the instance upon startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Data source to retrieve the current Google Cloud project ID.
# This is used by the gcloud commands in the null_resources.
data "google_project" "project" {}

# CRITICAL GCP NETWORKING: Implement get-or-create pattern for tenant VPC network.
# This null_resource runs a local-exec provisioner to create the VPC if it doesn't exist.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    # CRITICAL: Command first describes the network, and if it fails (exit code != 0), creates it.
    # '>/dev/null 2>&1' suppresses all output, relying on the exit code.
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
  }
}

# Data source to read the tenant VPC network configuration.
# CRITICAL: Explicit dependency ensures the VPC is provisioned before Terraform tries to read it.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# CRITICAL GCP NETWORKING: Implement get-or-create pattern for shared internal firewall rule.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# CRITICAL GCP NETWORKING: Implement get-or-create pattern for shared IAP SSH firewall rule.
# This rule is conditional and only provisioned for Linux VMs.
resource "null_resource" "allow_iap_ssh_provisioner" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create if OS type is Linux

  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Resource to generate a random integer for a unique subnet IP range.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
  # Ensure recreation if the instance name changes, assigning a new subnet.
  keepers = {
    instance_name = var.instance_name
  }
}

# CRITICAL GCP NETWORKING: Create a unique subnetwork for THIS deployment.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # Dynamic IP range.
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link # Associate with tenant VPC.

  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is provisioned first.
}

# FOR LINUX DEPLOYMENTS ONLY: Generate an SSH key pair.
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0 # Only generate if OS is Linux
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Primary compute resource for the virtual machine.
# CRITICAL: MUST be named "this_vm".
resource "google_compute_instance" "this_vm" {
  name                = var.instance_name
  machine_type        = var.vm_size
  zone                = "${var.region}-a" # Using a default zone within the specified region.
  deletion_protection = false              # CRITICAL: Set to false as per instructions.

  # Boot disk configuration.
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION: Use the exact and complete cloud image name.
      image = "ubuntu-22-04-19271224598"
    }
  }

  # CRITICAL STRUCTURE: Network interface configuration.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL NETWORKING REQUIREMENT: This empty block assigns an ephemeral public IP.
    # DO NOT MOVE IT from this exact location within the network_interface block.
    access_config {
    }
  }

  # CRITICAL STRUCTURE: Service account configuration.
  # This block MUST NOT contain an access_config.
  service_account {
    scopes = ["cloud-platform"] # Grant full access to GCP services for the VM's service account.
  }

  # Metadata for startup scripts and SSH keys.
  metadata = merge(
    var.custom_script != "" ? { "startup-script" = var.custom_script } : {},
    var.os_type == "Linux" ? { "ssh-keys" = "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" } : {},
  )

  # Conditional tags for the instance, based on OS type.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Ensure instance is created after necessary shared resources are ready.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    # The IAP firewall rule depends on os_type, so we conditionally include it.
    # If count is 0, the resource is not created, and so it cannot be a dependency.
    # However, since its count depends on os_type, which also drives the instance's metadata/tags,
    # the dependency is implicitly managed for the Linux case.
  ]
}

# CRITICAL GCP NETWORKING: Per-instance Firewall Rule for Public SSH (Linux only).
# Provides isolated public SSH access to this specific instance.
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create if OS type is Linux

  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Allow SSH from anywhere for public access.
  target_tags   = ["allow-ssh-${var.instance_name}"] # Target specific instance via its unique tag.
}

# CRITICAL GCP NETWORKING: Per-instance Firewall Rule for Public RDP (Windows only).
# Provides isolated public RDP access to this specific instance.
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create if OS type is Windows

  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"] # Allow RDP from anywhere for public access.
  target_tags   = ["allow-rdp-${var.instance_name}"] # Target specific instance via its unique tag.
}

# CRITICAL GCP NETWORKING: Per-instance Firewall Rule for Public WinRM (Windows only).
# Provides isolated public WinRM access to this specific instance.
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create if OS type is Windows

  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # Allow WinRM from anywhere for public access.
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-winrm-${var.instance_name}"] # Target specific instance via its unique tag.
}

# Output block: Expose the private IP address of the virtual machine.
output "private_ip" {
  description = "The private IP address of the created virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output block: Expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID of the virtual machine."
  value       = google_compute_instance.this_vm.instance_id
}

# Output block: Expose networking tags applied to the instance.
output "network_tags" {
  description = "The network tags applied to the Google Compute Instance."
  value       = google_compute_instance.this_vm.tags
}

# Output block: Expose the generated private SSH key, marked as sensitive.
# This output is conditional and will show "N/A" for Windows VMs.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing Linux instances."
  value       = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Windows VM or SSH key not generated."
  sensitive   = true # CRITICAL: Mark this output as sensitive to prevent logging.
}