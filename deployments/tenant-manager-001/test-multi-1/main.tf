# Configure the AWS provider
# This block specifies that we are using the AWS cloud provider
# and sets the default region for all resources.
provider "aws" {
  region = var.region
}

# --- Variables Block ---
# Define input variables for configuration flexibility.

variable "instance_name" {
  description = "Name for the virtual machine instance."
  type        = string
  default     = "test-multi-1" # Extracted from platform.instanceName
}

variable "region" {
  description = "AWS region where resources will be deployed."
  type        = string
  default     = "us-east-1" # Extracted from platform.region
}

variable "instance_type" {
  description = "The type of EC2 instance to deploy (e.g., t3.micro, m5.large)."
  type        = string
  default     = "t3.micro" # Extracted from platform.vmSize
}

variable "custom_script" {
  description = "An optional script to be executed on instance launch (user data)."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n" # Extracted from platform.customScript
}

# --- Data Sources Block ---
# Data sources are used to fetch information about existing resources.

# Data source to find the default VPC in the specified region.
# This is crucial for associating resources like security groups and subnets.
data "aws_vpc" "default" {
  default = true
}

# Data source to find all subnets within the default VPC.
# We need this to select a subnet for the EC2 instance.
# CRITICAL: Using "aws_subnets" (plural) as "aws_subnet_ids" is deprecated.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Data source to find the custom AMI for the instance.
# The image name is explicitly provided in the instructions.
data "aws_ami" "custom_image" {
  most_recent = true
  owners      = ["self"] # Assuming the custom AMI is owned by the current account.

  filter {
    name   = "name"
    values = ["amazon-linux-2023-19210138993"] # CRITICAL: Exact image name from instructions.
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- SSH Key Pair Generation (for Linux deployments) ---
# Generates a private and public SSH key pair for secure access.

# Resource to generate a local TLS private key.
# This private key will be used to access the EC2 instance.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: No 'comment' argument allowed for tls_private_key.
}

# AWS Key Pair resource to register the public key with AWS.
# This allows the EC2 instance to be launched with this key.
resource "aws_key_pair" "admin_key" {
  # CRITICAL: Using name_prefix to avoid collisions on retries.
  key_name_prefix = "${var.instance_name}-key-"
  public_key      = tls_private_key.admin_ssh.public_key_openssh
  tags = {
    Name = "${var.instance_name}-ssh-key"
  }
}

# --- AWS Security Group Configuration ---
# Creates a security group to control network traffic to and from the instance.

resource "aws_security_group" "this_sg" {
  # CRITICAL: Using name_prefix to avoid collisions on retries.
  name_prefix = "${var.instance_name}-sg-"
  description = "Security group for ${var.instance_name}"
  vpc_id      = data.aws_vpc.default.id # Associate with the default VPC.

  # CRITICAL: Allow all egress traffic (all protocols, all ports, to all destinations).
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # Represents all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  # CRITICAL: NO ingress blocks. Inbound traffic is blocked by default.

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# --- IAM Role and Instance Profile for SSM ---
# Required for AWS Systems Manager (SSM) agent connectivity and management.

# IAM Role that EC2 instances will assume.
# This role grants permissions to interact with AWS services.
resource "aws_iam_role" "ssm_role" {
  # CRITICAL: Using name_prefix for collision avoidance.
  name_prefix = "${var.instance_name}-ssm-role-"
  description = "IAM role for EC2 instances to allow SSM access"

  # Trust policy allowing EC2 instances to assume this role.
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

# Attach the AWS managed policy for SSM to the IAM role.
# This policy grants the necessary permissions for SSM to manage the instance.
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  # CRITICAL: Using the exact ARN for AmazonSSMManagedInstanceCore.
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM Instance Profile, which is a container for an IAM role.
# EC2 instances use instance profiles to make the role available to applications.
resource "aws_iam_instance_profile" "ssm_profile" {
  # CRITICAL: Using name_prefix for collision avoidance.
  name_prefix = "${var.instance_name}-ssm-profile-"
  role        = aws_iam_role.ssm_role.id # Link to the SSM IAM role.

  tags = {
    Name = "${var.instance_name}-ssm-profile"
  }
}

# --- Virtual Machine Deployment ---

# Primary compute resource: AWS EC2 Instance.
# CRITICAL: Resource named "this_vm" as per instructions.
resource "aws_instance" "this_vm" {
  ami           = data.aws_ami.custom_image.id # Use the ID of the custom AMI found by the data source.
  instance_type = var.instance_type             # Use the specified instance type.

  # CRITICAL AWS NETWORKING: Select the first available subnet from the default VPC.
  subnet_id = data.aws_subnets.default_subnets.ids[0]

  # CRITICAL AWS NETWORKING: Assign a public IP address for SSM connectivity.
  # The security group still controls inbound traffic.
  associate_public_ip_address = true

  # Associate the instance with the created security group.
  vpc_security_group_ids = [aws_security_group.this_sg.id]

  # CRITICAL: Attach the generated SSH key pair to the instance.
  key_name = aws_key_pair.admin_key.key_name

  # CRITICAL: Attach the IAM instance profile for SSM connectivity.
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  # CRITICAL USER DATA: Pass the custom script as base64 encoded user data.
  # FORBIDDEN to use 'user_data'.
  user_data_base64 = base64encode(var.custom_script)

  tags = {
    Name = var.instance_name
  }

  # CRITICAL: Explicit dependency to prevent race conditions during IAM setup.
  depends_on = [
    aws_iam_role_policy_attachment.ssm_policy_attach
  ]
}

# --- Outputs Block ---
# Expose important information about the deployed resources.

# CRITICAL: Output for the private IP address of the VM.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# CRITICAL: Output for the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID of the virtual machine."
  value       = aws_instance.this_vm.id
}

# CRITICAL: Output for the generated private SSH key.
# Marked as sensitive to prevent it from being displayed in plaintext in logs/CLI.
output "private_ssh_key" {
  description = "The private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # CRITICAL: MUST be marked as sensitive.
}