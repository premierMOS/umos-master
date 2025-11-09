# AWS Provider Configuration
# Defines the AWS region where resources will be deployed.
provider "aws" {
  region = var.region
}

# --- Input Variables ---

# Defines the AWS region for resource deployment.
variable "region" {
  description = "The AWS region to deploy resources into."
  type        = string
  default     = "us-east-1"
}

# Defines the name for the virtual machine instance.
variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-ssh-3"
}

# Defines the instance type (VM size) for the virtual machine.
variable "vm_size" {
  description = "The instance type for the virtual machine."
  type        = string
  default     = "t3.micro"
}

# --- Data Sources ---

# Data source to find the ID of the custom AMI based on its name.
# This AMI is pre-built and specified by the platform configuration.
data "aws_ami" "this_ami" {
  filter {
    name   = "name"
    values = ["amazon-linux-2023-19199576595"]
  }

  owners      = ["self"]
  most_recent = true
}

# Data source to retrieve information about the default VPC in the specified region.
data "aws_vpc" "default" {
  default = true
}

# Data source to retrieve all subnets within the default VPC.
# This ensures the instance is placed in an existing, default network configuration.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- Resources ---

# Resource to generate an SSH private and public key pair.
# This key pair will be used for administrative access to the Linux VM.
# CRITICAL: The 'comment' argument is FORBIDDEN for 'tls_private_key'.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# AWS resource to create a key pair, registering the public key with AWS.
# The private key is generated locally by 'tls_private_key.admin_ssh'.
resource "aws_key_pair" "admin_ssh" {
  key_name   = "${var.instance_name}-ssh-key"
  public_key = tls_private_key.admin_ssh.public_key_openssh
  tags = {
    Name = "${var.instance_name}-ssh-key"
  }
}

# AWS Security Group for the virtual machine.
# This security group allows all outbound traffic and explicitly forbids any inbound traffic
# as per the critical instruction.
resource "aws_security_group" "this_sg" {
  name        = "${var.instance_name}-sg"
  description = "Security group for ${var.instance_name} - Egress only"
  vpc_id      = data.aws_vpc.default.id

  # Allow all egress traffic (all protocols, all ports, to all destinations)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # CRITICAL: No ingress blocks are explicitly defined, adhering to the instruction.
  # If ingress is needed, it must be added carefully later.

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# Primary resource for deploying the AWS EC2 virtual machine instance.
resource "aws_instance" "this_vm" {
  # CRITICAL: Resource name MUST be "this_vm"
  ami                          = data.aws_ami.this_ami.id
  instance_type                = var.vm_size
  subnet_id                    = data.aws_subnets.default_subnets.ids[0] # Use the first available subnet in the default VPC.
  key_name                     = aws_key_pair.admin_ssh.key_name
  vpc_security_group_ids       = [aws_security_group.this_sg.id]

  # CRITICAL SECURITY REQUIREMENT: Virtual machines MUST NOT have public IP addresses.
  associate_public_ip_address = false

  # CRITICAL AWS SECURE CONNECTIVITY: Associate with an existing SSM instance profile.
  # This enables secure access via AWS Systems Manager.
  # CRITICAL: Value must be hardcoded string "ssm_instance_profile".
  iam_instance_profile = "ssm_instance_profile"

  tags = {
    Name = var.instance_name
  }
}

# --- Outputs ---

# Output the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Output the cloud provider's native instance ID of the virtual machine.
output "instance_id" {
  description = "The cloud provider's native instance ID of the virtual machine."
  value       = aws_instance.this_vm.id
}

# Output the generated private SSH key.
# CRITICAL: This output MUST be marked as sensitive to prevent it from being displayed in plaintext.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}