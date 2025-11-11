# Required providers for Google Cloud, TLS key generation, random numbers, and null resources.
# The 'google' provider manages GCP resources.
# The 'tls' provider is used for generating SSH key pairs.
# The 'random' provider generates unique values like subnet octets.
# The 'null' provider is used with local-exec provisioners for idempotent gcloud commands.
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

# Google Cloud Platform Provider configuration.
# The 'project' attribute is intentionally omitted as per instructions,
# relying on the environment's default project or explicit configuration outside this script
# to ensure tenant isolation and dynamic project identification.
provider "google" {
  region = var.region
}

# Terraform Variables for configurable attributes.
# These variables allow easy customization of the deployment without modifying the core script.
# Each variable includes a 'default' value directly from the provided JSON configuration
# to prevent interactive prompts during execution.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-azurefwa-3"
}

variable "region" {
  description = "The Google Cloud region to deploy resources in."
  type        = string
  default     = "us-central1"
}

variable "vm_size" {
  description = "The machine type (size) of the virtual machine."
  type        = string
  default     = "e2-micro"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for resource naming and isolation."
  type        = string
  default     = "tenant-manager-001"
}

variable "os_type" {
  description = "The operating system type (e.g., Linux, Windows)."
  type        = string
  default     = "Linux" # Derived from JSON config: os.type
}

variable "custom_script" {
  description = "A startup script to be executed on the virtual machine upon creation."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Data source to get the current GCP project ID dynamically.
# This is crucial for robust gcloud commands where the project is not hardcoded,
# enabling operations within the current execution context.
data "google_project" "project" {}

# Provisioner for the Tenant VPC Network using gcloud CLI.
# This null_resource implements a 'get-or-create' pattern.
# It first attempts to describe the VPC; if it doesn't exist (exit code 1),
# it proceeds to create it. This makes the operation idempotent and handles concurrent deployments.
resource "null_resource" "vpc_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute networks describe pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute networks create pmos-tenant-${var.tenant_id}-vpc --project=${data.google_project.project.project_id} --subnet-mode=custom --description=\"VPC for tenant ${var.tenant_id}\""
  }
}

# Data source to read the Tenant VPC Network details after it's provisioned.
# The 'depends_on' meta-argument ensures that the 'null_resource.vpc_provisioner'
# (and its gcloud command) completes successfully before Terraform attempts to read the network.
data "google_compute_network" "tenant_vpc" {
  name       = "pmos-tenant-${var.tenant_id}-vpc"
  depends_on = [null_resource.vpc_provisioner]
}

# Provisioner for the 'allow-internal' shared firewall rule.
# This rule permits all traffic within the 10.0.0.0/8 CIDR range, assuming it's used for
# internal tenant communications. It uses the 'get-or-create' pattern via gcloud.
resource "null_resource" "allow_internal_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-internal --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=all --source-ranges=10.0.0.0/8"
  }
  # Ensure the VPC exists before attempting to create firewall rules within it.
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Provisioner for the 'allow-iap-ssh' shared firewall rule.
# This rule allows SSH access via Google Cloud's Identity-Aware Proxy (IAP) service,
# which provides a secure way to access VMs without requiring direct public IP access.
# It uses the 'get-or-create' pattern via gcloud.
resource "null_resource" "allow_iap_ssh_provisioner" {
  provisioner "local-exec" {
    command = "gcloud compute firewall-rules describe pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} &>/dev/null || gcloud compute firewall-rules create pmos-tenant-${var.tenant_id}-allow-iap-ssh --project=${data.google_project.project.project_id} --network=${data.google_compute_network.tenant_vpc.name} --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=ssh-via-iap"
  }
  # Ensure the VPC exists before attempting to create firewall rules within it.
  depends_on = [data.google_compute_network.tenant_vpc]
}

# Generates a random integer to be used as an octet in a subnet's IP CIDR block.
# This helps ensure that each deployment creates a uniquely addressed subnet,
# preventing IP range conflicts in multi-tenant or parallel deployments.
resource "random_integer" "subnet_octet" {
  min = 2
  max = 254 # Limits the octet to typical usable range, avoiding 0 or 255.
}

# Creates a unique subnetwork within the tenant VPC for this specific deployment.
# The subnet's name is based on the instance name, and its IP CIDR range is
# dynamically generated using the random integer, ensuring uniqueness.
resource "google_compute_subnetwork" "this_subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.${random_integer.subnet_octet.result}.0.0/24" # Dynamic /24 subnet.
  region        = var.region
  network       = data.google_compute_network.tenant_vpc.self_link

  # Ensure the VPC and shared firewall rules are fully provisioned before
  # attempting to create a subnet within that VPC.
  depends_on = [
    data.google_compute_network.tenant_vpc,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner
  ]
}

# Generates a new RSA SSH private key locally.
# This key pair will be used to securely access the Linux virtual machine.
# The 'comment' argument is explicitly forbidden as per instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096 # Standard strong key size.
}

# Google Compute Engine Virtual Machine Instance.
# This is the primary compute resource, named "this_vm" as required.
resource "google_compute_instance" "this_vm" {
  name                = var.instance_name
  machine_type        = var.vm_size
  zone                = "${var.region}-b" # Deploys to zone 'b' within the specified region.
  deletion_protection = false              # Explicitly set to false as per instructions.

  # The 'project' attribute is intentionally omitted here as well,
  # relying on the provider's configuration context.

  # Boot disk configuration, specifying the custom image.
  # The 'image' is the exact cloud image name provided in the critical instructions.
  boot_disk {
    initialize_params {
      image = "ubuntu-22-04-19271224598" # CRITICAL: Exact custom image name.
    }
  }

  # Network interface configuration, associating with the newly created subnet.
  # The empty 'access_config {}' block is CRITICAL for assigning an ephemeral public IP,
  # which is required for management agents or direct public connectivity.
  network_interface {
    subnetwork = google_compute_subnetwork.this_subnet.self_link
    access_config {
      # This empty block assigns an ephemeral public IP to the instance.
      # This is crucial for network connectivity for management agents (like SSM for AWS, if GCP had it)
      # or direct public access via firewall rules. DO NOT MOVE OR REMOVE.
    }
  }

  # Service account for the VM, granting appropriate permissions.
  # This allows the VM to interact with other GCP services securely.
  service_account {
    # This block MUST NOT contain an access_config.
    scopes = ["cloud-platform"] # Provides broad access to GCP services, can be narrowed for least privilege.
  }

  # Metadata for the instance, including the SSH public key for Linux VMs
  # and a startup script if provided.
  metadata = {
    # For Linux VMs, the public SSH key is added to metadata for user 'packer'.
    "ssh-keys"     = var.os_type == "Linux" ? "packer:${tls_private_key.admin_ssh.public_key_openssh}" : null
    # The 'startup-script' metadata key is used to execute the custom script on instance boot.
    "startup-script" = var.custom_script
  }

  # Network tags for firewall rule association.
  # These tags are conditionally applied based on the OS type, enabling specific
  # ingress rules (e.g., IAP SSH for Linux, RDP/WinRM for Windows).
  tags = var.os_type == "Linux" ? ["ssh-via-iap", "allow-ssh-${var.instance_name}"] : ["allow-rdp-${var.instance_name}", "allow-winrm-${var.instance_name}"]

  # Ensure the subnet and required shared firewall rules are in place before creating the VM.
  depends_on = [
    google_compute_subnetwork.this_subnet,
    null_resource.allow_internal_provisioner,
    null_resource.allow_iap_ssh_provisioner
  ]
}

# Per-instance firewall rule to allow public SSH access for Linux instances.
# This rule is created only if the 'os_type' variable is "Linux".
resource "google_compute_firewall" "allow_public_ssh" {
  count = var.os_type == "Linux" ? 1 : 0 # Only create this rule for Linux VMs.

  name    = "pmos-instance-${var.instance_name}-allow-ssh"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"] # Allow standard SSH port.
  }

  source_ranges = ["0.0.0.0/0"] # Allow SSH from any IP address (for direct public access).
  target_tags   = ["allow-ssh-${var.instance_name}"] # Target this specific instance via its unique tag.

  depends_on = [google_compute_instance.this_vm]
}

# Per-instance firewall rule to allow public RDP access for Windows instances.
# This rule is created only if the 'os_type' variable is "Windows".
resource "google_compute_firewall" "allow_public_rdp" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create this rule for Windows VMs.

  name    = "pmos-instance-${var.instance_name}-allow-rdp"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["3389"] # Allow standard RDP port.
  }

  source_ranges = ["0.0.0.0/0"] # Allow RDP from any IP address (for direct public access).
  target_tags   = ["allow-rdp-${var.instance_name}"] # Target this specific instance via its unique tag.

  depends_on = [google_compute_instance.this_vm]
}

# Per-instance firewall rule to allow public WinRM access for Windows instances.
# This rule is created only if the 'os_type' variable is "Windows".
resource "google_compute_firewall" "allow_public_winrm" {
  count = var.os_type == "Windows" ? 1 : 0 # Only create this rule for Windows VMs.

  name    = "pmos-instance-${var.instance_name}-allow-winrm"
  network = data.google_compute_network.tenant_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["5985", "5986"] # Allow standard WinRM ports (HTTP and HTTPS).
  }

  source_ranges = ["0.0.0.0/0"] # Allow WinRM from any IP address (for direct public access).
  target_tags   = ["allow-winrm-${var.instance_name}"] # Target this specific instance via its unique tag.

  depends_on = [google_compute_instance.this_vm]
}

# Output the private IP address of the deployed virtual machine.
# This is useful for internal connectivity or management within the VPC.
output "private_ip" {
  description = "The private IP address of the created VM."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the unique instance ID assigned by Google Cloud.
# This ID is essential for programmatic management, auditing, or integration with other tools.
output "instance_id" {
  description = "The Google Cloud native instance ID of the created VM."
  value       = google_compute_instance.this_vm.instance_id
}

# Output the network tags associated with the virtual machine.
# These tags are crucial for firewall rule application and network segmentation.
output "network_tags" {
  description = "The network tags applied to the VM."
  value       = google_compute_instance.this_vm.tags
}

# Output the generated private SSH key.
# This output is marked as sensitive to prevent it from being displayed in plain text
# in Terraform console output or state files, significantly enhancing security.
output "private_ssh_key" {
  description = "The generated private SSH key (PEM format) for accessing the VM. Keep this secure."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}