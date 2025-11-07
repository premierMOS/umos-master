# Configure the Google Cloud provider
# The project and region are derived from the provided configuration.
provider "google" {
  project = "prod-gcp-project-123" # GCP Project ID from the configuration
  region  = "us-central1"         # Region for global resources, from platform.region
}

# Generate a new SSH key pair to be used for administrative access to the VM.
# The private key will be outputted and marked as sensitive.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Deploy the Google Compute Engine virtual machine instance.
# The resource is named "this_vm" as per instructions.
resource "google_compute_instance" "this_vm" {
  name         = "test-32"        # Instance name from platform.instanceName
  machine_type = "e2-micro"       # VM size from platform.vmSize
  zone         = "us-central1-a"  # A specific zone within the specified region

  # Configure the boot disk for the VM.
  # The image name is from the critical instructions "Actual Cloud Image Name".
  boot_disk {
    initialize_params {
      # Use the specific custom image name provided.
      image = "ubuntu-20-04-19181965819" # Actual Cloud Image Name from instructions
    }
  }

  # Define the network interface for the VM.
  # Assumes the 'default' VPC network exists.
  network_interface {
    network = "default" # Connects to the default VPC network

    # An access_config block assigns an ephemeral public IP address.
    # This allows direct SSH access from the internet if firewall rules permit.
    access_config {
      // Ephemeral public IP will be assigned
    }
  }

  # Add metadata to the instance, including the SSH public key.
  # This allows logging in as the 'packer' user with the generated private key.
  metadata = {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # Set deletion protection for the instance as required.
  deletion_protection = false

  # Optional: Apply labels for better organization and management.
  labels = {
    environment = "development"
    managed_by  = "terraform"
  }
}

# Output the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed Google Compute Engine instance."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the generated private SSH key.
# This output is marked as sensitive to prevent it from being displayed in logs.
output "private_ssh_key" {
  description = "The private SSH key (PEM format) generated for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}