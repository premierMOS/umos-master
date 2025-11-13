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

# AWS Provider Configuration
provider "aws" {
  region = var.region
}

# --- Input Variables ---

# Name of the EC2 instance
variable "instance_name" {
  type        = string
  description = "Name for the virtual machine instance."
  default     = "test-full"
}

# AWS region for deployment
variable "region" {
  type        = string
  description = "AWS region where the virtual machine will be deployed."
  default     = "us-east-1"
}

# Size of the virtual machine
variable "vm_size" {
  type        = string
  description = "Instance type (VM size) for the virtual machine."
  default     = "t3.micro"
}

# Tenant identifier for resource naming and tagging
variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant."
  default     = "tenant-manager-001"
}

# Custom script to run on instance startup (user data)
variable "custom_script" {
  type        = string
  description = "Optional script to be executed upon instance launch."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# --- Data Sources ---

# Look up the default VPC
data "aws_vpc" "default" {
  default = true
}

# Look up all subnets within the default VPC
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Look up the custom AMI by its exact name
data "aws_ami" "custom_image" {
  filter {
    name   = "name"
    values = ["amazon-linux-2023-19315310214"]
  }
  owners      = ["self"]
  most_recent = true
}

# Look up existing shared security groups for the tenant
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# --- SSH Key Pair Generation ---

# Generate a new TLS private key for SSH access
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create an AWS EC2 Key Pair from the generated public key
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-"
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}

# --- IAM Role and Instance Profile for AWS SSM ---

# Create an IAM role for EC2 instances to allow SSM communication
resource "aws_iam_role" "ssm_role" {
  name_prefix        = "${var.instance_name}-ssm-role-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
  tags = {
    InstanceName = var.instance_name
    TenantId     = var.tenant_id
  }
}

# Attach the AmazonSSMManagedInstanceCore policy to the IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an IAM instance profile to attach the role to the EC2 instance
resource "aws_iam_instance_profile" "ssm_profile" {
  name_prefix = "${var.instance_name}-ssm-profile-"
  role        = aws_iam_role.ssm_role.name
  # description is forbidden here as per instructions
  tags = {
    InstanceName = var.instance_name
    TenantId     = var.tenant_id
  }
}

# --- Shared Security Group (Get-or-Create Pattern) ---

# Conditionally create a shared security group if one does not already exist
resource "aws_security_group" "tenant_shared_sg" {
  count = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0

  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for tenant ${var.tenant_id} - allows internal communication"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule: Allow all traffic from within this security group (self-referencing)
  ingress {
    protocol  = "-1" # All protocols
    from_port = 0
    to_port   = 0
    self      = true # Allows traffic from other resources associated with this security group
    # description is forbidden here as per instructions
  }

  # Egress rule: Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
    # description is forbidden here as per instructions
  }

  tags = {
    Name     = "pmos-tenant-${var.tenant_id}-sg"
    TenantId = var.tenant_id
  }
}

# Local variable to determine the ID of the shared security group to use
locals {
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]
}

# --- Virtual Machine Deployment ---

# Deploy the AWS EC2 instance
resource "aws_instance" "this_vm" {
  # Explicitly wait for the IAM role policy attachment to complete
  depends_on = [aws_iam_role_policy_attachment.ssm_policy_attach]

  ami                          = data.aws_ami.custom_image.id
  instance_type                = var.vm_size
  key_name                     = aws_key_pair.admin_key.key_name
  associate_public_ip_address  = true # Required for SSM agent in public subnets
  subnet_id                    = data.aws_subnets.default_subnets.ids[0] # Use the first available default subnet
  vpc_security_group_ids       = [local.shared_sg_id]                     # Attach the shared security group
  iam_instance_profile         = aws_iam_instance_profile.ssm_profile.name # Attach SSM instance profile
  user_data_base64             = base64encode(var.custom_script)           # Pass custom script as user data

  tags = {
    Name     = var.instance_name
    TenantId = var.tenant_id
  }
}

# --- Outputs ---

# Output the private IP address of the deployed virtual machine
output "private_ip" {
  description = "The private IP address of the EC2 instance."
  value       = aws_instance.this_vm.private_ip
}

# Output the AWS instance ID of the deployed virtual machine
output "instance_id" {
  description = "The ID of the EC2 instance."
  value       = aws_instance.this_vm.id
}

# Output the generated private SSH key (marked as sensitive)
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}