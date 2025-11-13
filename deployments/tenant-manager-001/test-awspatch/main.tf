# --- IAM ROLE CLARIFICATION ---
# This Terraform script creates an IAM Role and Instance Profile for the EC2 instance.
# This role attaches the "AmazonSSMManagedInstanceCore" policy, allowing the SSM Agent
# ON THE INSTANCE to communicate with the AWS SSM service for management.
#
# IMPORTANT: The user or service that SENDS commands (like patching jobs from Premier Managed OS)
# needs a SEPARATE set of permissions, specifically "ssm:SendCommand".
#
# Please ensure the IAM role running your CI/CD pipeline has this permission. You can find the
# required policy in this app's "Settings > Amazon Web Services > Required IAM Permissions" section.
# This script ONLY handles the instance's permissions, not the caller's.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Configure the AWS provider with the specified region
provider "aws" {
  region = var.region
}

# Declare variables with default values pulled directly from the JSON configuration
variable "instance_name" {
  type    = string
  default = "test-awspatch"
  description = "Name of the EC2 instance."
}

variable "region" {
  type    = string
  default = "us-east-1"
  description = "AWS region to deploy the instance."
}

variable "vm_size" {
  type    = string
  default = "t3.micro"
  description = "EC2 instance type (e.g., t3.micro)."
}

variable "tenant_id" {
  type    = string
  default = "tenant-manager-001"
  description = "Unique identifier for the tenant, used for resource naming."
}

variable "custom_script" {
  type    = string
  default = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
  description = "Custom script to be executed on instance startup (user data)."
}

variable "os_image_name_full" {
  type    = string
  default = "amazon-linux-2023-19315310214"
  description = "The exact name of the custom OS image (AMI) to use."
}

# --- Data Sources for existing AWS resources ---

# Data source to find the default VPC in the account
data "aws_vpc" "default" {
  default = true
}

# Data source to find all subnets within the default VPC
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Data source to find the custom AMI based on the exact name provided
data "aws_ami" "custom_image" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = [var.os_image_name_full]
  }
}

# Data source to look up an existing shared security group for the tenant
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# --- Shared Security Group (Get-or-Create Pattern) ---

# Conditionally create a new shared security group if it doesn't already exist
resource "aws_security_group" "tenant_shared_sg" {
  count = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0

  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for PMOS tenant ${var.tenant_id}"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule to allow all traffic from resources within this security group (self-referencing)
  ingress {
    protocol  = "-1" # All protocols
    from_port = 0
    to_port   = 0
    self      = true # Allows traffic from other instances associated with this SG
  }

  # Egress rule to allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "pmos-tenant-${var.tenant_id}-sg"
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# Local variable to determine which security group ID to use (existing or newly created)
locals {
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]
}

# --- SSH Key Pair for Linux Instances ---

# Generate a new private key for SSH access
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create an AWS EC2 Key Pair using the public key generated above
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-"
  public_key      = tls_private_key.admin_ssh.public_key_openssh

  tags = {
    Name    = "${var.instance_name}-key"
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# --- IAM Role and Instance Profile for SSM ---

# Create an IAM Role that EC2 instances can assume
resource "aws_iam_role" "ssm_role" {
  name_prefix = "${var.instance_name}-ssm-role-"
  description = "IAM role for EC2 instance to allow SSM agent communication"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    Name    = "${var.instance_name}-ssm-role"
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# Attach the AmazonSSMManagedInstanceCore policy to the IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an IAM Instance Profile to associate the role with the EC2 instance
resource "aws_iam_instance_profile" "ssm_profile" {
  name_prefix = "${var.instance_name}-ssm-profile-"
  role        = aws_iam_role.ssm_role.name

  tags = {
    Name    = "${var.instance_name}-ssm-profile"
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# --- EC2 Virtual Machine Deployment ---

# Deploy the primary EC2 instance
resource "aws_instance" "this_vm" {
  ami                         = data.aws_ami.custom_image.id
  instance_type               = var.vm_size
  subnet_id                   = data.aws_subnets.default_subnets.ids[0] # Use the first available default subnet
  associate_public_ip_address = true                                   # Required for SSM agent in public subnet
  vpc_security_group_ids      = [local.shared_sg_id]                   # Attach the shared security group
  key_name                    = aws_key_pair.admin_key.key_name        # Attach the SSH key pair
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name # Attach the SSM instance profile
  user_data_base64            = base64encode(var.custom_script)        # Pass custom script as user data

  # Explicitly depend on the policy attachment to prevent race conditions during instance launch
  depends_on = [aws_iam_role_policy_attachment.ssm_policy_attach]

  tags = {
    Name    = var.instance_name
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# --- Outputs ---

# Output the private IP address of the deployed virtual machine
output "private_ip" {
  description = "The private IP address of the EC2 instance."
  value       = aws_instance.this_vm.private_ip
}

# Output the cloud provider's native instance ID
output "instance_id" {
  description = "The ID of the EC2 instance."
  value       = aws_instance.this_vm.id
}

# Output the generated private SSH key (marked as sensitive)
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}