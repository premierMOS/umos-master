# Provider configuration for AWS
provider "aws" {
  region = "us-east-1" # Region specified in the JSON configuration
}

# --- Data Sources ---

# Data source to retrieve information about the default VPC.
# This is crucial for placing resources in the default network environment.
data "aws_vpc" "default" {
  default = true
}

# Data source to retrieve all subnets within the default VPC.
# We filter by the ID of the default VPC found above.
# The instance will be placed in the first available subnet.
# CRITICAL: Using "aws_subnets" (plural) as "aws_subnet_ids" is deprecated.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Data source to find the custom Amazon Machine Image (AMI).
# The image name is explicitly provided in the instructions.
# 'owners = ["self"]' ensures we only look for AMIs owned by our account.
# 'most_recent = true' selects the latest version if multiple match the name.
# CRITICAL: Using the exact image name provided in the instructions.
data "aws_ami" "custom_image" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["amazon-linux-2023-19199576595"] # CRITICAL: Exact image name from instructions
  }
}

# --- SSH Key Pair Generation ---

# Resource to generate a new RSA private key for SSH access.
# This key is used for the AWS Key Pair.
# CRITICAL: This resource MUST be named "admin_ssh".
# CRITICAL: The 'comment' argument is FORBIDDEN for this resource.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Resource to create an AWS EC2 Key Pair using the public key from the generated SSH key.
# This allows SSH connectivity to instances launched with this key.
resource "aws_key_pair" "admin_ssh_key" {
  key_name   = "admin-ssh-key-test-ssh-4" # Derived from instance name
  public_key = tls_private_key.admin_ssh.public_key_openssh
}

# --- Security Group Configuration ---

# Resource to define a security group for the virtual machine.
# It controls inbound and outbound network traffic to the instance.
# CRITICAL: This resource MUST be named "this_sg".
# CRITICAL: Name MUST be based on instance name from JSON + "-sg".
# CRITICAL: The name MUST NOT start with "sg-".
resource "aws_security_group" "this_sg" {
  name        = "test-ssh-4-sg" # "instanceName-sg" from JSON config
  description = "Security group for test-ssh-4"
  vpc_id      = data.aws_vpc.default.id # Associate with the default VPC

  # Egress rule: Allow all outbound traffic.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  # CRITICAL: No 'ingress' blocks are specified as per security requirements.
}

# --- Virtual Machine Deployment ---

# Primary compute resource: AWS EC2 Instance.
# CRITICAL: This resource MUST be named "this_vm".
resource "aws_instance" "this_vm" {
  # AMI ID retrieved from the data source for the custom image.
  ami                         = data.aws_ami.custom_image.id
  instance_type               = "t3.micro" # VM size from JSON configuration

  # CRITICAL SECURITY REQUIREMENT: Do NOT associate a public IP address.
  # Instances must be private.
  associate_public_ip_address = false

  # CRITICAL: Use the ID of the first available subnet from the default VPC subnets.
  subnet_id = data.aws_subnets.default_subnets.ids[0]

  # CRITICAL: Associate the instance with the security group created above.
  vpc_security_group_ids = [aws_security_group.this_sg.id]

  # CRITICAL: Attach the AWS Key Pair created from the generated SSH key.
  key_name = aws_key_pair.admin_ssh_key.key_name

  # CRITICAL: Hardcode the SSM Instance Profile name as instructed.
  # This enables AWS Systems Manager connectivity.
  # FORBIDDEN from creating or looking up this profile resource.
  iam_instance_profile = "ssm_instance_profile"

  # User data script for initial instance configuration, as provided in JSON.
  user_data = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"

  # Tags for identification and management.
  tags = {
    Name = "test-ssh-4" # Instance name from JSON configuration
  }
}

# --- Output Variables ---

# Output the private IP address of the virtual machine.
# CRITICAL: Output name MUST be "private_ip".
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Output the cloud provider's native instance ID.
# CRITICAL: Output name MUST be "instance_id".
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = aws_instance.this_vm.id
}

# Output the generated private SSH key.
# CRITICAL: Output name MUST be "private_ssh_key" and MUST be sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the VM (sensitive)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}