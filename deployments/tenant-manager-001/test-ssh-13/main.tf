# Define the AWS provider and specify the region from the configuration
provider "aws" {
  region = "us-east-1"
}

# Variable to hold the instance name, making the configuration reusable
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-ssh-13" # Default value from the JSON config
}

# --- Data Sources for AWS Environment Discovery ---

# Data source to find the default VPC in the AWS account
# This ensures resources are deployed into the standard network environment.
data "aws_vpc" "default" {
  default = true
}

# Data source to find all subnets associated with the default VPC.
# This is used to place the VM in one of the existing network segments.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Data source to look up the custom AMI by its exact name.
# This ensures the VM is launched with the specified, pre-built image.
data "aws_ami" "custom_image" {
  filter {
    name   = "name"
    values = ["amazon-linux-2023-19199576595"]
  }
  owners      = ["self"]        # Look for AMIs owned by the current account
  most_recent = true            # Select the most recent matching AMI
}

# --- SSH Key Pair Generation for Linux Instances ---

# Resource to generate a new TLS private key locally.
# This key will be used for SSH access to the Linux VM.
# The 'comment' argument is explicitly forbidden as per instructions.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# AWS resource to create a key pair from the generated public key.
# 'key_name_prefix' is used to avoid naming collisions on retries.
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-"
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}

# --- Network Security Group Configuration ---

# Resource to create an AWS Security Group for the VM.
# 'name_prefix' is used for unique naming, based on the instance name.
# It explicitly allows all outbound traffic and no inbound traffic,
# relying on AWS Systems Manager for secure access, not SSH directly.
resource "aws_security_group" "this_sg" {
  name_prefix = "${var.instance_name}-sg-"
  description = "Security group for ${var.instance_name}"
  vpc_id      = data.aws_vpc.default.id

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  # CRITICAL: No ingress rules are defined as per instructions.
  # Access is expected to be managed via AWS Systems Manager.
}

# --- Virtual Machine Deployment ---

# Primary compute resource: AWS EC2 Instance.
# Named "this_vm" as per critical instructions.
resource "aws_instance" "this_vm" {
  ami                         = data.aws_ami.custom_image.id
  instance_type               = "t3.micro" # From JSON vmSize
  subnet_id                   = data.aws_subnets.default_subnets.ids[0] # Use the first available default subnet

  # CRITICAL SECURITY REQUIREMENT: DO NOT associate a public IP address.
  associate_public_ip_address = false

  # Associate the security group created for this instance.
  vpc_security_group_ids = [aws_security_group.this_sg.id]

  # Attach the generated SSH key pair for initial setup/login (if allowed by SG rules, but for this setup, SSM is preferred).
  key_name = aws_key_pair.admin_key.key_name

  # CRITICAL AWS SECURE CONNECTIVITY INSTRUCTION:
  # Directly assign the assumed existing IAM Instance Profile for Systems Manager access.
  # No IAM resources are read or created by this script.
  iam_instance_profile = "premier_managed_os_ssm_role"

  # Standard tags for identification and management.
  tags = {
    Name = var.instance_name
  }
}

# --- Output Blocks ---

# Output the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The unique ID of the virtual machine instance."
  value       = aws_instance.this_vm.id
}

# Output the generated private SSH key.
# CRITICAL: This output is marked as sensitive to prevent it from being displayed
# in plain text in Terraform logs. Store this securely!
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance (handle with extreme care)."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}