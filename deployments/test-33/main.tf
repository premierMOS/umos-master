# This Terraform script deploys a virtual machine on Amazon Web Services (AWS).
# It creates an EC2 instance, generates an SSH key pair, and configures a security group
# to allow SSH access.

# Configure the AWS provider
provider "aws" {
  region = local.region # AWS region for deploying resources
}

# Define local variables for configuration values extracted from JSON
locals {
  instance_name    = "test-33"                          # Name for the EC2 instance (from platform.instanceName)
  region           = "us-east-1"                        # AWS region (from platform.region)
  vm_size          = "t3.micro"                         # Instance type (from platform.vmSize)
  image_name       = "ubuntu-20-04-19182851935"         # Specific custom image name as per instructions
  user_data_script = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n" # User data script (from platform.customScript)
}

# Data source to find the default VPC ID in the specified region
data "aws_vpc" "default" {
  default = true
}

# Generate a new TLS private key for SSH access.
# This resource creates an RSA key pair.
# CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create an AWS EC2 Key Pair using the public key from the generated TLS private key.
# This key pair will be associated with the EC2 instance for SSH authentication.
resource "aws_key_pair" "admin_keypair" {
  key_name   = "${local.instance_name}-key" # Name for the key pair, incorporating instance name for uniqueness
  public_key = tls_private_key.admin_ssh.public_key_openssh
}

# Data source to retrieve the ID of a custom Amazon Machine Image (AMI).
# This finds the specified custom Ubuntu 20.04 image within the current account.
data "aws_ami" "this_ami" {
  # CRITICAL: Using the actual cloud image name provided in the instructions.
  name        = local.image_name
  owners      = ["self"]       # Search for AMIs owned by the current account
  most_recent = true           # Select the most recent matching AMI

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Create an AWS Security Group to control inbound and outbound traffic for the VM.
# This security group allows SSH (port 22) from any IP address.
resource "aws_security_group" "this_vm_sg" {
  name        = "${local.instance_name}-sg" # Name for the security group
  description = "Allow SSH inbound traffic"
  vpc_id      = data.aws_vpc.default.id      # Associate with the default VPC

  # Ingress rule: Allow SSH from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # WARNING: 0.0.0.0/0 allows access from any IP. Restrict in production.
    description = "Allow SSH from anywhere"
  }

  # Egress rule: Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"          # -1 specifies all protocols
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${local.instance_name}-sg"
  }
}

# Primary compute resource: AWS EC2 Instance
resource "aws_instance" "this_vm" {
  # CRITICAL: The primary compute resource MUST be named "this_vm".
  ami                    = data.aws_ami.this_ami.id        # AMI ID retrieved from the data source
  instance_type          = local.vm_size                   # EC2 instance type (e.g., t3.micro)
  key_name               = aws_key_pair.admin_keypair.key_name # Associate the generated SSH key pair
  vpc_security_group_ids = [aws_security_group.this_vm_sg.id] # Attach the created security group
  user_data              = local.user_data_script          # Script to run on instance launch

  tags = {
    Name = local.instance_name # Tag the instance with its name
  }
}

# Output block: Expose the private IP address of the virtual machine
output "private_ip" {
  # CRITICAL: Output block MUST be named "private_ip".
  # For AWS, this value is 'aws_instance.this_vm.private_ip'.
  value       = aws_instance.this_vm.private_ip
  description = "The private IP address of the created virtual machine."
}

# Output block: Expose the generated private SSH key
output "private_ssh_key" {
  # CRITICAL: This output MUST be named "private_ssh_key" and marked as sensitive.
  # The block MUST look exactly as specified.
  value     = tls_private_key.admin_ssh.private_key_pem
  sensitive = true
  description = "The generated private SSH key for connecting to the virtual machine. Store this securely."
}