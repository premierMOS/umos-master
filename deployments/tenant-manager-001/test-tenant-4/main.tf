# Configure the Google Cloud provider.
# The 'project' attribute is intentionally omitted as per critical instructions;
# it will be inherited from the credentials configured in the environment.
provider "google" {
  region = "us-central1" # Specified region from the configuration
}

# Resource to generate a new SSH key pair.
# This key will be used for SSH access to the virtual machine.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA" # Use RSA algorithm for SSH key generation
  rsa_bits  = 4096  # Set the key length to 4096 bits for enhanced security
}

# Deploy a Google Compute Engine virtual machine.
# The resource is named 'this_vm' as required.
resource "google_compute_instance" "this_vm" {
  name         = "test-tenant-4" # Instance name from the configuration
  machine_type = "e2-micro"      # VM size from the configuration
  zone         = "us-central1-a" # A specific zone within the specified region.
                                 # Google Cloud instances require a zone, not just a region.

  # Boot disk configuration for the virtual machine.
  # The 'image' specifies the custom image to be used.
  boot_disk {
    initialize_params {
      image = "ubuntu-20-04-19183856194" # Custom image name as per critical instructions
    }
  }

  # Network interface configuration.
  # This sets up a default network interface with an ephemeral public IP address.
  network_interface {
    network = "default" # Use the default VPC network
    access_config {     # Attach a public IP for external connectivity
      // Ephemeral public IP
    }
  }

  # Metadata for the instance, including SSH keys for administrative access.
  # The 'ssh-keys' entry allows 'packer' user to log in using the generated SSH key.
  metadata = {
    ssh-keys = "packer:${tls_private_key.admin_ssh.public_key_openssh}"
  }

  # Set deletion protection to false as per critical GCP instructions.
  deletion_protection = false

  # The 'project' attribute is intentionally omitted as per critical instructions;
  # it will be inherited from the provider's configuration.
}

# Output the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = google_compute_instance.this_vm.network_interface[0].network_ip
}

# Output the generated private SSH key.
# This output is marked as sensitive to prevent it from being displayed in plaintext in logs.
output "private_ssh_key" {
  description = "The private SSH key for accessing the virtual machine."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}