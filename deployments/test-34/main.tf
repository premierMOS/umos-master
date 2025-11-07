# Configure the AWS provider
provider "aws" {
  region = "us-east-1" # Region specified in the configuration
}

# Generate a new SSH key pair for admin access
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
}

# (Optional) Generate a unique suffix for resource names to prevent conflicts
resource "random_id" "tag" {
  byte_length = 8
}

# Create an AWS Key Pair from the generated public key
resource "aws_key_pair" "admin_key" {
  key_name   = "this-vm-key-${random_id.tag.hex}" # Unique key name to avoid conflicts
  public_key = tls_private_key.admin_ssh.public_key_openssh
}

# Data source to find the custom AMI by its name
# This specifically looks for the "Actual Cloud Image Name" provided in the instructions.
data "aws_ami" "this_ami" {
  most_recent = true # Get the most recent AMI if multiple match
  owners      = ["self"] # Look for AMIs owned by your account

  filter {
    name   = "name"
    values = ["ubuntu-20-04-19182851935"] # Actual Cloud Image Name as specified
  }
}

# Deploy the virtual machine resource
resource "aws_instance" "this_vm" {
  # Use the AMI ID found by the data source
  ami           = data.aws_ami.this_ami.id
  instance_type = "t3.micro" # VM size from configuration
  key_name      = aws_key_pair.admin_key.key_name # Attach the generated SSH key pair

  # Tag the instance with its name from the configuration
  tags = {
    Name = "test-34" # Instance name from configuration
  }

  # User data scripts are mentioned as "not yet supported for direct deployment",
  # so the 'user_data' argument is intentionally omitted.
}

# Output block for the private IP address of the created virtual machine
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Output block for the generated private SSH key
# This output is marked as sensitive and should be handled with extreme care.
output "private_ssh_key" {
  value     = tls_private_key.admin_ssh.private_key_pem
  sensitive = true
}