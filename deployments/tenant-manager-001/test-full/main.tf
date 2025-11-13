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

provider "aws" {
  region = var.region
}

# Terraform Variables for key configuration values
variable "instance_name" {
  type        = string
  description = "Name for the EC2 instance."
  default     = "test-full"
}

variable "region" {
  type        = string
  description = "AWS region where resources will be deployed."
  default     = "us-east-1"
}

variable "vm_size" {
  type        = string
  description = "EC2 instance type (e.g., t3.micro)."
  default     = "t3.micro"
}

variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant, used for resource naming."
  default     = "tenant-manager-001"
}

variable "custom_script" {
  type        = string
  description = "User data script to run on instance launch."
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# CRITICAL IMAGE NAME INSTRUCTION: The exact and complete cloud image name to use for lookups.
variable "os_image_name" {
  type        = string
  description = "The exact name of the custom AMI to use for the instance lookup."
  default     = "amazon-linux-2023-19315310214"
}

# Data source to find the default VPC
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

# Data source to find the custom AMI by its exact name
data "aws_ami" "custom_image" {
  most_recent = true
  owners      = ["self"] # Search for AMIs owned by the current AWS account

  filter {
    name   = "name"
    values = [var.os_image_name]
  }
}

# Data source to check for an existing shared security group based on tenant ID
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# Conditionally create the shared security group if it doesn't already exist
resource "aws_security_group" "tenant_shared_sg" {
  count = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0

  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for tenant ${var.tenant_id} allowing intra-group communication."
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule: Allow all traffic from instances associated with this security group (self-referencing)
  ingress {
    protocol  = "-1" # All protocols
    from_port = 0
    to_port   = 0
    self      = true # Allows traffic from within this security group
    # CRITICAL: FORBIDDEN from including a 'description' argument here.
  }

  # Egress rule: Allow all outbound traffic to any destination
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
    # CRITICAL: FORBIDDEN from including a 'description' argument here.
  }

  tags = {
    Name      = "pmos-tenant-${var.tenant_id}-sg"
    TenantId  = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# Local variable to dynamically select the security group ID (either existing or newly created)
locals {
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ?
                 aws_security_group.tenant_shared_sg[0].id :
                 data.aws_security_groups.existing_shared_sg.ids[0]
}

# Generate a new SSH key pair for administrative access
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: FORBIDDEN from including a 'comment' argument in this resource block.
}

# Create an AWS Key Pair resource using the generated SSH public key
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-" # Use prefix to avoid naming collisions
  public_key      = tls_private_key.admin_ssh.public_key_openssh

  tags = {
    Name      = "${var.instance_name}-ssh-key"
    TenantId  = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# IAM Role to allow the EC2 instance to assume a role for SSM management
resource "aws_iam_role" "ssm_role" {
  name_prefix        = "${var.instance_name}-ssm-role-" # Use prefix to avoid naming collisions
  path               = "/"
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
    Name      = "${var.instance_name}-ssm-role"
    TenantId  = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# Attach the AWS managed policy for SSM to the IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an IAM Instance Profile to associate the SSM role with the EC2 instance
resource "aws_iam_instance_profile" "ssm_profile" {
  name_prefix = "${var.instance_name}-ssm-profile-" # Use prefix to avoid naming collisions
  role        = aws_iam_role.ssm_role.id
  # CRITICAL: FORBIDDEN from including a 'description' argument to this resource block.
}

# Primary EC2 virtual machine resource deployment
resource "aws_instance" "this_vm" {
  ami                         = data.aws_ami.custom_image.id            # Use the ID of the custom AMI
  instance_type               = var.vm_size                              # Instance size from variable
  subnet_id                   = data.aws_subnets.default_subnets.ids[0]  # Use the first default subnet
  associate_public_ip_address = true                                   # CRITICAL: Required for SSM Agent in default public subnets
  vpc_security_group_ids      = [local.shared_sg_id]                     # Attach the shared security group
  key_name                    = aws_key_pair.admin_key.key_name          # Attach the generated SSH key pair
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name # Attach the SSM instance profile
  user_data_base64            = base64encode(var.custom_script)          # CRITICAL: Use user_data_base64 for custom scripts

  tags = {
    Name      = var.instance_name
    TenantId  = var.tenant_id
    ManagedBy = "Terraform"
  }

  # CRITICAL: Explicitly depend on the policy attachment to prevent race conditions
  depends_on = [
    aws_iam_role_policy_attachment.ssm_policy_attach,
  ]
}

# Output block: Expose the private IP address of the VM
output "private_ip" {
  description = "The private IP address of the EC2 instance."
  value       = aws_instance.this_vm.private_ip
}

# Output block: Expose the cloud provider's native instance ID
output "instance_id" {
  description = "The AWS-provided ID of the EC2 instance."
  value       = aws_instance.this_vm.id
}

# Output block: Expose the generated private SSH key, marked as sensitive
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}