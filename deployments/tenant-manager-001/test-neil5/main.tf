# Configure the AWS Provider
provider "aws" {
  region = var.region
}

# --- Data Sources ---

# Data source to find the default VPC in the specified region.
# This ensures resources are deployed within an existing default network.
data "aws_vpc" "default" {
  default = true
}

# Data source to find all subnets associated with the default VPC.
# CRITICAL: Using "aws_subnets" (plural) as "aws_subnet_ids" is deprecated and forbidden.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Data source to find the custom Amazon Machine Image (AMI) for the instance.
# CRITICAL: Using the exact image name provided in the instructions,
# as custom images have specific build-generated names.
data "aws_ami" "custom_image" {
  owners      = ["self"]       # Look for AMIs owned by the current account
  most_recent = true           # Select the most recent version of the image
  filter {
    name   = "name"
    values = ["amazon-linux-2023-19210138993"] # Exact custom image name
  }
}

# --- SSH Key Pair Generation (Linux Deployments Only) ---

# Generates a new RSA private key locally for administrative SSH access.
# This key is used to secure the instance.
# CRITICAL: The 'comment' argument is explicitly forbidden for 'tls_private_key'.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096 # Recommended bit size for strong security
}

# Creates an AWS EC2 Key Pair resource using the generated public key.
# This makes the public key available to EC2 instances.
# CRITICAL: Using 'key_name_prefix' to avoid naming collisions on retries.
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-" # Prefix based on instance name
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}

# --- Networking Resources ---

# Creates a security group for the virtual machine.
# This controls inbound and outbound network traffic.
# CRITICAL: Using 'name_prefix' to avoid naming collisions on retries.
# CRITICAL: No ingress rules are allowed by the security instructions.
resource "aws_security_group" "this_sg" {
  name_prefix = "${var.instance_name}-sg-" # Prefix based on instance name
  description = "Security group for ${var.instance_name}"
  vpc_id      = data.aws_vpc.default.id # Associate with the default VPC

  # Allow all egress traffic (all protocols, all ports, to all destinations '0.0.0.0/0').
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"                # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]       # All IP addresses
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# --- Virtual Machine Deployment ---

# Deploys the primary virtual machine instance.
# CRITICAL: The resource name MUST be "this_vm" as per instructions.
resource "aws_instance" "this_vm" {
  # Instance configuration
  ami           = data.aws_ami.custom_image.id # Use the ID of the custom AMI found
  instance_type = var.instance_type            # Instance size from variables

  # Networking configuration
  # CRITICAL SECURITY REQUIREMENT: Virtual machines MUST NOT have public IP addresses.
  associate_public_ip_address = false
  # CRITICAL: Assign to the first available subnet from the default VPC data source.
  subnet_id                   = data.aws_subnets.default_subnets.ids[0]
  # Associate the instance with the created security group.
  vpc_security_group_ids      = [aws_security_group.this_sg.id]

  # SSH Key Pair for access
  # CRITICAL: Attaching the generated AWS Key Pair for SSH access.
  key_name = aws_key_pair.admin_key.key_name

  # User data for initial instance setup.
  # CRITICAL: Using 'user_data_base64' and the 'base64encode()' function for custom scripts.
  # 'user_data' is forbidden.
  user_data_base64 = base64encode(var.custom_script)

  # IAM Instance Profile for Systems Manager (SSM) access.
  # This enables secure management and remote access via AWS Systems Manager.
  # CRITICAL: Hardcoded IAM instance profile name for secure connectivity.
  # FORBIDDEN: Any 'resource "aws_iam_role"', 'resource "aws_iam_instance_profile"',
  # or corresponding 'data' sources are not permitted.
  iam_instance_profile = " premier_managed_os_ssm_role"

  # Tags for identification and management within AWS.
  tags = {
    Name = var.instance_name
    OS   = "Amazon Linux 2023" # Based on the specified custom image
  }
}

# --- Variables ---

# Defines the AWS region where resources will be deployed.
variable "region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1" # Default derived from JSON configuration
}

# Defines the name of the EC2 instance.
variable "instance_name" {
  description = "Name of the EC2 instance."
  type        = string
  default     = "test-neil5" # Default derived from JSON configuration
}

# Defines the instance type (VM size) for the EC2 instance.
variable "instance_type" {
  description = "The EC2 instance type (VM size)."
  type        = string
  default     = "t3.micro" # Default derived from JSON configuration
}

# Custom script to be executed on instance startup.
# CRITICAL: This variable is declared as a string to hold the custom script.
variable "custom_script" {
  description = "Optional custom script to run on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n" # Default derived from JSON configuration
}

# --- Outputs ---

# Exposes the private IP address of the created virtual machine.
# CRITICAL: Output block MUST be named "private_ip".
output "private_ip" {
  description = "The private IP address of the EC2 instance."
  value       = aws_instance.this_vm.private_ip
}

# Exposes the cloud provider's native instance ID.
# CRITICAL: Output block MUST be named "instance_id".
output "instance_id" {
  description = "The ID of the EC2 instance."
  value       = aws_instance.this_vm.id
}

# Exposes the generated private SSH key.
# CRITICAL: Output block MUST be named "private_ssh_key" and marked as sensitive.
output "private_ssh_key" {
  description = "The private SSH key generated for administrative access. KEEP THIS SECURE!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # Mark as sensitive to prevent display in standard Terraform output
}