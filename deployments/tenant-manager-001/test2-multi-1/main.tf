# Configure the AWS provider
# This block specifies the cloud provider and region for resource deployment.
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

# Provider configuration for AWS
# The region is dynamically set using a variable.
provider "aws" {
  region = var.region
}

# Declare variables for flexible configuration
# These variables allow easy customization of the VM without modifying the core script.
variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test2-multi-1"
}

variable "region" {
  description = "AWS region to deploy the resources."
  type        = string
  default     = "us-east-1"
}

variable "vm_size" {
  description = "Instance type (e.g., t3.micro, m5.large) for the VM."
  type        = string
  default     = "t3.micro"
}

variable "custom_script" {
  description = "Shell script to be executed on the VM startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Data source to retrieve information about the default VPC
# This ensures that resources are deployed within the existing default network infrastructure.
data "aws_vpc" "default" {
  default = true
}

# Data source to retrieve IDs of all subnets within the default VPC
# We filter by the default VPC ID to ensure correct network placement.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Data source to find the custom AMI for the virtual machine
# Uses a specific image name provided, ensuring the correct OS is deployed.
data "aws_ami" "custom_image" {
  owners      = ["self"] # Look for AMIs owned by the current AWS account.
  most_recent = true     # Select the most recent version of the matching AMI.

  filter {
    name   = "name"
    values = ["amazon-linux-2023-19210138993"] # Exact image name as per instructions.
  }
}

# Resource to generate a new SSH private key locally
# This key pair will be used for secure SSH access to the Linux VM.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: DO NOT add a 'comment' argument here as forbidden by instructions.
}

# Resource to create an AWS EC2 Key Pair
# The public key from the generated SSH key is registered with AWS.
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-" # Use prefix to avoid naming collisions.
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}

# Resource to create a security group for the virtual machine
# This security group allows all outbound traffic but no inbound traffic by default,
# relying on SSM for secure access.
resource "aws_security_group" "this_sg" {
  vpc_id = data.aws_vpc.default.id        # Associate with the default VPC.
  name_prefix = "${var.instance_name}-sg-" # Use prefix to avoid naming collisions.
  description = "Allow all egress traffic"

  # Egress rule: Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  # CRITICAL: No ingress rules as per instructions. Access is via SSM.
  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# Resource to create an IAM role for the EC2 instance
# This role grants necessary permissions for the instance to interact with AWS services,
# particularly AWS Systems Manager (SSM).
resource "aws_iam_role" "ssm_role" {
  name_prefix        = "${var.instance_name}-ssm-role-" # Use prefix to avoid naming collisions.
  description        = "IAM role for SSM access to EC2 instance"
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
}

# Resource to attach the AWS managed policy for SSM to the IAM role
# This policy grants the instance permissions required to be managed by SSM.
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Resource to create an IAM instance profile
# The instance profile is a container for an IAM role that you can attach to an EC2 instance.
resource "aws_iam_instance_profile" "ssm_profile" {
  name_prefix = "${var.instance_name}-ssm-profile-" # Use prefix to avoid naming collisions.
  role        = aws_iam_role.ssm_role.name           # Associate with the SSM role.
}

# Primary resource for deploying the AWS EC2 virtual machine
# This block defines all the properties and configurations for the EC2 instance.
resource "aws_instance" "this_vm" {
  ami                         = data.aws_ami.custom_image.id        # Custom image ID from data source.
  instance_type               = var.vm_size                         # Instance size from variable.
  subnet_id                   = data.aws_subnets.default_subnets.ids[0] # First available subnet in default VPC.
  vpc_security_group_ids      = [aws_security_group.this_sg.id]     # Attach the custom security group.
  associate_public_ip_address = true                                # CRITICAL: Required for SSM agent in public subnets.
  key_name                    = aws_key_pair.admin_key.key_name     # Attach the generated SSH key pair.
  user_data_base64            = base64encode(var.custom_script)     # Base64 encoded custom startup script.
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name # Attach the SSM instance profile.

  # CRITICAL: Explicit dependency to prevent race conditions during IAM role attachment.
  depends_on = [
    aws_iam_role_policy_attachment.ssm_policy_attach
  ]

  tags = {
    Name = var.instance_name # Tag the instance with its specified name.
  }
}

# Output block to expose the private IP address of the virtual machine
# Useful for internal network access or for debugging.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Output block to expose the cloud provider's native instance ID
# This ID is unique within the cloud provider and can be used for direct API calls.
output "instance_id" {
  description = "The cloud provider's native instance ID for the virtual machine."
  value       = aws_instance.this_vm.id
}

# Output block to expose the generated private SSH key
# CRITICAL: This output is marked as sensitive to prevent it from being displayed in plaintext
# in Terraform logs, enhancing security.
output "private_ssh_key" {
  description = "The generated private SSH key for secure access to the instance. This value is sensitive."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}