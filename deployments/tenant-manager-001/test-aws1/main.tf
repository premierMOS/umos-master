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

# AWS Provider Configuration
provider "aws" {
  region = var.region
}

# Input Variables
variable "instance_name" {
  type        = string
  description = "Name for the virtual machine instance."
  default     = "test-aws1"
}

variable "region" {
  type        = string
  description = "AWS region where the resources will be deployed."
  default     = "us-east-1"
}

variable "vm_size" {
  type        = string
  description = "Size or type of the virtual machine."
  default     = "t3.micro"
}

variable "tenant_id" {
  type        = string
  description = "Unique identifier for the tenant."
  default     = "tenant-manager-001"
}

variable "custom_script" {
  type        = string
  description = "User-provided script to run on the VM after deployment."
  default     = "# Enter your post-deployment script here.\n# For Linux, it will be executed via bash.\n# For Windows, it will be executed via PowerShell.\n"
}

variable "image_name_lookup" {
  type        = string
  description = "The exact name of the custom image to use for the VM."
  default     = "windows-2019-aws-19395304151"
}

# --- Data Sources ---

# Look up the custom AMI by its exact name
data "aws_ami" "custom_image" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = [var.image_name_lookup]
  }
}

# Look up the default VPC
data "aws_vpc" "default" {
  default = true
}

# Look up subnets within the default VPC
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Look up for an existing shared security group for the tenant
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# --- Resources ---

# Generates a random password for the Windows Administrator account
resource "random_password" "admin_password" {
  length        = 16
  special       = true
  override_special = "_!@#&"
}

# IAM Role for SSM Agent communication
resource "aws_iam_role" "ssm_role" {
  name_prefix        = "${var.instance_name}-ssm-role-"
  description        = "IAM role for EC2 instances to communicate with AWS SSM service."
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
    Name = "${var.instance_name}-ssm-role"
  }
}

# Attach the AmazonSSMManagedInstanceCore policy to the IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM Instance Profile to attach the role to the EC2 instance
resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.instance_name}-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# Conditionally create a shared security group for the tenant if it doesn't exist
resource "aws_security_group" "tenant_shared_sg" {
  count  = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0
  name   = "pmos-tenant-${var.tenant_id}-sg"
  vpc_id = data.aws_vpc.default.id
  tags = {
    Name = "pmos-tenant-${var.tenant_id}-sg"
  }

  # Ingress rule allowing all traffic from within the same security group (self-referencing)
  ingress {
    protocol = "-1" # All protocols
    self     = true # Allows traffic from instances associated with this security group
  }

  # Egress rule allowing all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Local Values ---

locals {
  # Determine the shared security group ID: either existing or newly created
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]

  # User data script for Windows instances, ensuring SSM agent and setting admin password
  user_data_script = <<-EOT
  <powershell>
  # Ensure the SSM Agent service is set to automatic and start it
  Set-Service -Name "AmazonSSMAgent" -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name "AmazonSSMAgent" -ErrorAction SilentlyContinue

  # Set Administrator password
  $Password = ConvertTo-SecureString -String "${random_password.admin_password.result}" -AsPlainText -Force
  Set-LocalUser -Name "Administrator" -Password $Password

  # User-provided script follows
  ${var.custom_script}
  </powershell>
  EOT
}

# Primary Virtual Machine Resource
resource "aws_instance" "this_vm" {
  ami                            = data.aws_ami.custom_image.id
  instance_type                  = var.vm_size
  subnet_id                      = data.aws_subnets.default_subnets.ids[0]
  associate_public_ip_address    = true # Required for SSM agent in public subnets
  vpc_security_group_ids         = [local.shared_sg_id]
  iam_instance_profile           = aws_iam_instance_profile.ssm_profile.name
  user_data                      = local.user_data_script

  tags = {
    Name      = var.instance_name
    Tenant_ID = var.tenant_id
  }

  # Explicit dependency to ensure the instance profile is fully provisioned before instance creation
  depends_on = [
    aws_iam_instance_profile.ssm_profile,
    aws_security_group.tenant_shared_sg # Ensure SG is created if count > 0
  ]
}


# --- Outputs ---

output "private_ip" {
  description = "The private IP address of the virtual machine."
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