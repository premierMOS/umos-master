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

# --- Input Variables ---

# Name for the EC2 instance
variable "instance_name" {
  description = "The name of the EC2 instance."
  type        = string
  default     = "test-patcha"
}

# AWS region to deploy the instance
variable "region" {
  description = "The AWS region where the resources will be deployed."
  type        = string
  default     = "us-east-1"
}

# EC2 instance type (e.g., t3.micro, t3.small)
variable "vm_size" {
  description = "The EC2 instance type."
  type        = string
  default     = "t3.micro"
}

# Unique identifier for the tenant, used for naming resources
variable "tenant_id" {
  description = "Unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

# Cloud image name for the OS (as provided in instructions for lookup)
variable "os_image_name" {
  description = "The exact cloud image name to use for AMI lookup."
  type        = string
  default     = "amazon-linux-2023-19315310214"
}

# Custom script to run on instance startup (user data)
variable "custom_script" {
  description = "A custom script to execute on the instance during initialization."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}


# --- Data Sources for existing AWS resources ---

# Lookup the default VPC
data "aws_vpc" "default" {
  default = true
}

# Lookup subnets within the default VPC
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Lookup the custom AMI ID by its exact name
data "aws_ami" "custom_image" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = [var.os_image_name]
  }
}

# Data source to check for an existing shared security group
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# --- Local Variables ---

locals {
  # Determine the shared security group ID: use existing if found, otherwise the one created.
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]
}


# --- SSH Key Pair Generation ---

# Generate a new TLS private key for SSH access
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Create an AWS Key Pair using the generated public key
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-"
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}


# --- IAM Role and Instance Profile for SSM Management ---

# IAM Role for EC2 instance to allow SSM agent communication
resource "aws_iam_role" "ssm_role" {
  name_prefix        = "${var.instance_name}-ssm-role-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
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
    TenantId    = var.tenant_id
    ManagedBy   = "PMOS"
    InstanceName = var.instance_name
  }
}

# Attach the AmazonSSMManagedInstanceCore policy to the IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an IAM Instance Profile for the EC2 instance
resource "aws_iam_instance_profile" "ssm_profile" {
  name_prefix = "${var.instance_name}-ssm-profile-"
  role        = aws_iam_role.ssm_role.name
}


# --- Shared Security Group (Get-or-Create) ---

# Conditionally create a shared security group for the tenant
resource "aws_security_group" "tenant_shared_sg" {
  count = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0

  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for tenant ${var.tenant_id} managed by PMOS"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule: Allow all traffic from instances within this security group (self-referencing)
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Egress rule: Allow all outbound traffic to anywhere
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    TenantId    = var.tenant_id
    ManagedBy   = "PMOS"
    InstanceName = var.instance_name
  }
}


# --- EC2 Virtual Machine Deployment ---

# Deploy the primary EC2 virtual machine
resource "aws_instance" "this_vm" {
  depends_on = [
    aws_iam_role_policy_attachment.ssm_policy_attach
  ]

  ami                          = data.aws_ami.custom_image.id
  instance_type                = var.vm_size
  subnet_id                    = data.aws_subnets.default_subnets.ids[0]
  associate_public_ip_address  = true # Required for SSM agent in public subnets
  key_name                     = aws_key_pair.admin_key.key_name
  vpc_security_group_ids       = [local.shared_sg_id]
  iam_instance_profile         = aws_iam_instance_profile.ssm_profile.name
  user_data_base64             = base64encode(var.custom_script)

  tags = {
    Name        = var.instance_name
    TenantId    = var.tenant_id
    ManagedBy   = "PMOS"
  }
}


# --- Outputs ---

# Expose the private IP address of the virtual machine
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Expose the cloud provider's native instance ID
output "instance_id" {
  description = "The unique ID of the virtual machine within the cloud provider."
  value       = aws_instance.this_vm.id
}

# Expose the generated private SSH key (sensitive)
output "private_ssh_key" {
  description = "The private SSH key generated for accessing the instance. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}