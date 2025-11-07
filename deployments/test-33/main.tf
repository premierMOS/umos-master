# Configure the Google Cloud provider
# The project ID is automatically inherited from the credentials configured in the environment.
# As per critical instructions, DO NOT include the 'project' attribute in the provider block.
provider "google" {
  region = "us-central1" # Region specified in the configuration
}

# Generate a new TLS private key for SSH access
# This resource is required for Linux deployments to create an SSH key pair.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Deploy a Google Compute Engine virtual machine instance
# CRITICAL INSTRUCTION: The primary compute resource MUST be named "this_vm".
resource "google_compute_instance" "this_vm" {
  # VM instance name from the configuration
  name         = "test-33"
  # Machine type (VM size) from the configuration
  machine_type = "e2-micro"
  # Zone within the specified region. Using a common zone 'a' for us-central1.
  zone         = "us-central1-a"

  # CRITICAL INSTRUCTION: OMIT the 'project' attribute from this resource block.
  # The project ID is automatically inherited from the credentials configured in the environment.

  # Boot disk configuration
  boot_disk {
    initialize_params {
      # CRITICAL INSTRUCTION: Use the actual cloud image name 'ubuntu-20-04-19181965819'.
      # This overrides any image IDs present in the JSON configuration for GCP.
      image = "ubuntu-20-04-19181965819"
      type  = "pd-standard" # Default disk type
      size  = 50            # Default disk size
    }
  }

  # Network interface configuration
  network_interface {
    network = "default" # Use the default VPC network

    # Assign an ephemeral public IP for external connectivity.
    # This allows SSH access from outside the GCP network.
    access_config {}
  }

  # Metadata for the VM, including SSH keys
  metadata = {
    # CRITICAL INSTRUCTION: Add the generated public SSH key for user 'packer'.
    # The format must be 'packer:${tls_private_key.admin_ssh.public_key_openssh}'.
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # Deletion protection for the VM
  # CRITICAL INSTRUCTION: Use 'deletion_protection' (not 'delete_protection') and set to false.
  deletion_protection = false

  # Optional: Configure a service account for the VM if it needs to access other GCP services.
  # service_account {
  #   scopes = ["cloud-platform"]
  # }
}

# Output the private IP address of the virtual machine.
# CRITICAL INSTRUCTION: Output block must be named "private_ip".
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  # CRITICAL INSTRUCTION: For GCP, the value is google_compute_instance.this_vm.network_interface[0].network_ip.
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the generated private SSH key.
# CRITICAL INSTRUCTION: Output block must be named "private_ssh_key" and marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key for accessing the VM. Keep this secure!"
  # CRITICAL INSTRUCTION: The value must be tls_private_key.admin_ssh.private_key_pem.
  value     = tls_private_key.admin_ssh.private_key_pem
  sensitive = true # Mark as sensitive to prevent its value from being shown in logs.
}