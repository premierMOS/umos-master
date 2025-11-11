# Required Providers
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

# Google Cloud Provider Configuration
provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# INPUT VARIABLES
#
# These variables define key configuration values for the VM deployment.
# Each variable includes a default value derived directly from the JSON config.
# -----------------------------------------------------------------------------

variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-gcpfwn-3"
}

variable "region" {
  description = "Google Cloud region for the deployment."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "Machine type for the virtual machine (e.g., e2-micro, n1-standard-1)."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used in resource naming to ensure isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "Operating system type of the VM (Linux or Windows)."
  type        = string
  default     = "Linux"
}

variable "project_id" {
  description = "The GCP project ID where resources will be deployed."
  type        = string
  default     = "umos-ab24d"
}

variable "custom_script" {
  description = "Custom script to run on instance startup (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# -----------------------------------------------------------------------------
# GCP TENANT VPC NETWORK (GET-OR-CREATE)
#
# This block ensures that a tenant-specific VPC network exists or is created.
# It uses a null_resource with a local-exec provisioner to run gcloud commands.
# -----------------------------------------------------------------------------

resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command     = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} >/dev/null 2>&1 || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${var.project_id} --subnet-mode=custom --description='VPC for tenant ${var.tenant_id}'"
    interpreter = ["bash", "-c"]
  }

  triggers = {
    tenant_vpc_name = "pmos-tenant-${var.tenant_id}-vpc"
    project_id      = var.project_id
  }
}

# Data source to read the provisioned VPC network details
# This ensures that subsequent resources can reference the VPC's attributes.
data "google_compute_network" "tenant_vpc" {
  depends_on = [null_resource.vpc_provisioner] # Ensure VPC is provisioned before reading
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  project    = var.project_id
}

# -----------------------------------------------------------------------------
# GCP SHARED FIREWALL RULES (GET-OR-CREATE)
#
# These blocks ensure that common, tenant-wide firewall rules exist or are created.
# They use the same get-or-create pattern as the VPC network.
# -----------------------------------------------------------------------------

resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command     = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8 --description='Allow all internal traffic within 10.0.0.0/8 for tenant ${var.tenant_id}'"
    interpreter = ["bash", "-c"]
  }

  triggers = {
    firewall_rule_name = "pmos-tenant-${var.tenant_id}-allow-internal"
    project_id         = var.project_id
    vpc_name           = data.google_compute_network.tenant_vpc.name
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}

resource "null_resource" "allow_iap_ssh_provisioner" {
  # This rule is only needed for Linux instances that use SSH via IAP.
  count = var.os_type == "Linux" ? 1 : 0

  provisioner "local-exec" {
    command     = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} >/dev/null 2>&1 || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${var.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap --description='Allow IAP SSH access for tenant ${var.tenant_id}'"
    interpreter = ["bash", "-c"]
  }

  triggers = {
    firewall_rule_name = "pmos-tenant-${var.tenant_id}-allow-iap-ssh"
    project_id         = var.project_id
    vpc_name           = data.google_compute_network.tenant_vpc.name
  }
  depends_on = [data.google_compute_network.tenant_vpc]
}


# -----------------------------------------------------------------------------
# UNIQUE SUBNET PROVISIONING
#
# Generates a unique IP range and creates a new subnet for this specific deployment.
# This prevents IP conflicts during concurrent deployments of instances in the same VPC.
# -----------------------------------------------------------------------------

resource "random_integer" "subnet_octet_2" {
  min = 1
  max = 254
  keepers = {
    instance_name = var.instance_name # Ensure uniqueness per instance deployment
  }
}

resource "random_integer" "subnet_octet_3" {
  min = 0
  max = 254
  keepers = {
    instance_name = var.instance_name # Ensure uniqueness per instance deployment
  }
}

resource "google_compute_subnetwork" "this_subnet" {
  project       = var.project_id
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet_2.result}.${random_integer.subnet_octet_3.result}.0/24"
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link
  depends_on    = [
    null_resource.vpc_provisioner # Ensure VPC exists before creating subnet
  ]
}

# -----------------------------------------------------------------------------
# PER-INSTANCE PUBLIC FIREWALL RULES
#
# Creates specific firewall rules for the instance's public access based on OS type.
# These rules target the specific instance using its unique tags.
# -----------------------------------------------------------------------------

resource "google_compute_firewall" "allow_public_ssh" {
  # Only create for Linux instances
  count = var.os_type == "Linux" ? 1 : 0

  project       = var.project_id
  name          = "pmos-instance-${var.instance_name}-allow-ssh"
  network       = data.google_compute_network.tenant_vpc.self_link
  target_tags   = ["allow-ssh-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  description = "Allow public SSH access to ${var.instance_name} (Linux)"
  depends_on  = [data.google_compute_network.tenant_vpc]
}

resource "google_compute_firewall" "allow_public_rdp" {
  # Only create for Windows instances
  count = var.os_type == "Windows" ? 1 : 0

  project       = var.project_id
  name          = "pmos-instance-${var.instance_name}-allow-rdp"
  network       = data.google_compute_network.tenant_vpc.self_link
  target_tags   = ["allow-rdp-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
  description = "Allow public RDP access to ${var.instance_name} (Windows)"
  depends_on  = [data.google_compute_network.tenant_vpc]
}

resource "google_compute_firewall" "allow_public_winrm" {
  # Only create for Windows instances
  count = var.os_type == "Windows" ? 1 : 0

  project       = var.project_id
  name          = "pmos-instance-${var.instance_name}-allow-winrm"
  network       = data.google_compute_network.tenant_vpc.self_link
  target_tags   = ["allow-winrm-${var.instance_name}"]
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # Standard WinRM ports
  }
  description = "Allow public WinRM access to ${var.instance_name} (Windows)"
  depends_on  = [data.google_compute_network.tenant_vpc]
}


# -----------------------------------------------------------------------------
# SSH KEY GENERATION (FOR LINUX ONLY)
#
# Generates a new SSH key pair using `tls_private_key` for Linux instances.
# -----------------------------------------------------------------------------

resource "tls_private_key" "admin_ssh" {
  count     = var.os_type == "Linux" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
  # The 'comment' argument is forbidden as per instructions.
}

# -----------------------------------------------------------------------------
# VIRTUAL MACHINE DEPLOYMENT
#
# This is the main compute resource for deploying the virtual machine.
# -----------------------------------------------------------------------------

resource "google_compute_instance" "this_vm" {
  project      = var.project_id
  name         = var.instance_name
  machine_type = var.vm_size
  zone         = "${var.region}-a" # Defaulting to zone 'a' within the specified region

  boot_disk {
    initialize_params {
      # CRITICAL IMAGE NAME INSTRUCTION: Use the provided exact custom image name.
      image = "ubuntu-22-04-19271224598"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      // Ephemeral public IP is assigned here to allow direct external access.
    }
  }

  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"] # Grant default Cloud API access
  }

  # CRITICAL METADATA STRUCTURE: All metadata must be in a single map block.
  metadata = {
    startup-script = var.custom_script
    # SSH keys are added for Linux instances; omitted for Windows.
    ssh-keys       = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh[0].public_key_openssh}" : null
  }

  # Apply unique tags for firewall rules and IAP access.
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  deletion_protection = false # Set to false to allow easy cleanup

  # CRITICAL DEPENDENCY INSTRUCTION:
  # Explicitly list all resources the VM depends on. Terraform handles resources
  # with count=0 in this list gracefully. Do NOT use conditional logic here.
  depends_on = [
    tls_private_key.admin_ssh,             # For SSH keys if Linux
    null_resource.vpc_provisioner,         # For VPC to exist
    null_resource.allow_internal_provisioner, # For internal firewall rule
    null_resource.allow_iap_ssh_provisioner,  # For IAP SSH firewall rule if Linux
    google_compute_subnetwork.this_subnet,    # For subnet to exist
    google_compute_firewall.allow_public_ssh, # For public SSH rule if Linux
    google_compute_firewall.allow_public_rdp, # For public RDP rule if Windows
    google_compute_firewall.allow_public_winrm, # For public WinRM rule if Windows
  ]
}

# -----------------------------------------------------------------------------
# OUTPUTS
#
# These outputs expose key information about the deployed virtual machine,
# enabling easy retrieval of essential details after deployment.
# -----------------------------------------------------------------------------

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

output "public_ip" {
  description = "The public IP address of the virtual machine (if assigned)."
  value       = google_compute_instance.this_vm.network_interface[0].access_config[0].nat_ip
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
  description = "The generated private SSH key for Linux instances (sensitive)."
  # Accessing tls_private_key.admin_ssh[0] only if count was > 0.
  value     = var.os_type == "Linux" ? tls_private_key.admin_ssh[0].private_key_pem : "N/A - Not a Linux instance"
  sensitive = true
}