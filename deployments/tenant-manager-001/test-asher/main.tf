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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

provider "aws" {
  region = var.region
}

# --- Variables for Configuration Values ---

variable "instance_name" {
  description = "The name of the EC2 instance."
  type        = string
  default     = "test-asher"
}

variable "region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

variable "vm_size" {
  description = "The EC2 instance type (e.g., t3.micro, m5.large)."
  type        = string
  default     = "t3.micro"
}

variable "tenant_id" {
  description = "The unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "A custom script to execute on the VM after deployment."
  type        = string
  default     = "# Enter your post-deployment script here.\n# For Linux, it will be executed via bash.\n# For Windows, it will be executed via PowerShell.\n"
}

# --- Data Sources ---

# Look up the default VPC in the specified region.
data "aws_vpc" "default" {
  default = true
}

# Look up all subnets associated with the default VPC.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  # CRITICAL: 'lifecycle' block or 'ignore_changes' argument are forbidden for data sources.
}

# Look up the custom Windows AMI by its exact name.
data "aws_ami" "custom_image" {
  owners      = ["self"]
  most_recent = true
  filter {
    name   = "name"
    values = ["windows-2019-19395304151"]
  }
  # CRITICAL: 'lifecycle' block or 'ignore_changes' argument are forbidden for data sources.
}

# Attempt to find an existing shared security group for the tenant.
# This supports the "get-or-create" pattern.
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
  # CRITICAL: 'lifecycle' block or 'ignore_changes' argument are forbidden for data sources.
}

# --- Locals Block ---
locals {
  # Determine the ID of the shared security group.
  # If an existing one is found, use its ID; otherwise, use the ID of the newly created one.
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]

  # User data script for Windows instances.
  # This script sets the Administrator password, ensures the SSM Agent is running,
  # and then executes any custom script provided.
  user_data_script = <<-EOT
    <powershell>
    # Set the Administrator password
    $Password = ConvertTo-SecureString -String "${random_password.admin_password.result}" -AsPlainText -Force
    Set-LocalUser -Name "Administrator" -Password $Password
    # Ensure the SSM Agent service is set to automatic and start it
    Set-Service -Name "AmazonSSMAgent" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "AmazonSSMAgent" -ErrorAction SilentlyContinue
    # User-provided script follows
    ${var.custom_script}
    </powershell>
    EOT
}

# --- Resources ---

# Generates a strong, random password for the Windows administrator account.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&"
}

# Creates a shared security group for the tenant if it does not already exist.
resource "aws_security_group" "tenant_shared_sg" {
  count = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0

  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for tenant ${var.tenant_id} - allows all internal traffic."
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule to allow all traffic from resources within this security group.
  ingress {
    protocol  = "-1" # All protocols
    from_port = 0
    to_port   = 0
    self      = true
    # CRITICAL: The 'description' argument is forbidden for ingress blocks.
  }

  # Egress rule to allow all outbound traffic to any destination.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
    # CRITICAL: The 'description' argument is forbidden for egress blocks.
  }

  tags = {
    Name    = "pmos-tenant-${var.tenant_id}-sg"
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# IAM Role that grants EC2 instances permissions to interact with AWS services,
# specifically required for SSM Agent to communicate with the SSM service.
resource "aws_iam_role" "ssm_role" {
  name_prefix = "${var.instance_name}-ssm-role-"
  description = "Allows EC2 instances to call AWS services on your behalf for SSM."

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

# Attaches the AWS-managed policy for SSM to the IAM role.
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM Instance Profile to attach the IAM role to an EC2 instance.
resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.instance_name}-ssm-profile"
  role = aws_iam_role.ssm_role.name
  # CRITICAL: The 'description' argument is forbidden for 'aws_iam_instance_profile'.
}

# Primary EC2 Virtual Machine deployment.
resource "aws_instance" "this_vm" {
  ami                         = data.aws_ami.custom_image.id
  instance_type               = var.vm_size
  subnet_id                   = data.aws_subnets.default_subnets.ids[0]
  vpc_security_group_ids      = [local.shared_sg_id]
  associate_public_ip_address = true # Assigns a public IP, required for SSM agent in public subnets (security groups still filter inbound).

  # User data script executed on instance launch for Windows configuration (password, SSM, custom script).
  user_data = local.user_data_script

  # Attaches the IAM instance profile for SSM access.
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  # Explicit dependency to ensure the instance profile is fully created before being attached to the instance.
  depends_on = [
    aws_iam_instance_profile.ssm_profile,
  ]

  tags = {
    Name    = var.instance_name
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# --- Output Block ---

output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = aws_instance.this_vm.private_ip
}

output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = aws_instance.this_vm.id
}

output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}