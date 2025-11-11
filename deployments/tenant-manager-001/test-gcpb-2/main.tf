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
  }
}

# The 'project' attribute is omitted from the provider configuration as per critical instructions
provider "google" {
  region = var.region
}

# Declare Terraform variables for key configuration values with default values from JSON
variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpb-2"
}

variable "region" {
  description = "Google Cloud region where the VM will be deployed."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Google Cloud zone where the VM will be deployed (derived from region)."
  type        = string
  default     = "us-central1-c" # A common zone within the specified region
}

variable "vm_size" {
  description = "Machine type for the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "custom_script" {
  description = "User data script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

# Data source to retrieve the current Google Cloud project ID
data "google_project" "project" {}

# Generate an SSH key pair for administrative access
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: 'comment' argument is forbidden for tls_private_key
}

# CRITICAL NETWORKING REQUIREMENT: Get-or-Create Tenant VPC Network
# This null_resource runs a local-exec provisioner to check if the VPC exists
# and creates it if it doesn't, making the operation idempotent.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the tenant VPC network, ensuring it's available after creation attempt
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  # CRITICAL: Explicit dependency to ensure VPC creation attempt completes first
  depends_on = [null_resource.vpc_provisioner]
}

# CRITICAL NETWORKING REQUIREMENT: Get-or-Create Firewall Rule for Internal Traffic
# This null_resource checks if the internal firewall rule exists and creates it if not.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8 --description=\"Allow all internal traffic for tenant ${var.tenant_id}\""
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating firewall rule
}

# CRITICAL NETWORKING REQUIREMENT: Get-or-Create Firewall Rule for IAP SSH Access
# This null_resource checks if the IAP SSH firewall rule exists and creates it if not.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap --description=\"Allow IAP SSH access for tenant ${var.tenant_id}\""
  }
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC exists before creating firewall rule
}

# Generate a random integer for a unique subnet IP range
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254
}

# Create a unique subnet for this deployment within the tenant VPC
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link

  # Ensure VPC and firewall rules are provisioned before creating the subnet
  depends_on = [
    null_resource.vpc_provisioner,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner,
  ]
}

# Primary compute resource: Google Compute Engine Virtual Machine
resource "google_compute_instance" "this_vm" {
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = var.zone
  # CRITICAL: OMIT 'project' attribute from instance block

  # Apply the IAP SSH tag for firewall rule matching
  tags = ["ssh-via-iap"]

  # CRITICAL: Set deletion protection to false as specified
  deletion_protection = false

  # Boot disk configuration, using the specified custom image
  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME: Use the exact provided image name
      image = "ubuntu-22-04-19271224598"
    }
  }

  # CRITICAL STRUCTURE: Network interface configuration
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    # CRITICAL NETWORKING REQUIREMENT: Empty access_config block to assign an ephemeral public IP
    access_config {
      # This block MUST remain empty to assign an ephemeral public IP
    }
  }

  # CRITICAL STRUCTURE: Service account for instance permissions
  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"]
  }

  # Metadata for SSH key and startup script
  metadata = {
    ssh-keys       = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
    startup-script = var.custom_script # CRITICAL: For GCP, user data is passed as metadata_startup_script
  }
}

# Output the private IP address of the created virtual machine
output "private_ip" {
  description = "The private IP address of the VM instance."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the cloud provider's native instance ID
output "instance_id" {
  description = "The unique ID of the VM instance within Google Cloud."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the generated private SSH key, marked as sensitive
output "private_ssh_key" {
  description = "The private SSH key generated for admin access to the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}