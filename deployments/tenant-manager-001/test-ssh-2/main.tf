# AWS Provider Configuration
provider "aws" {
  region = local.region
}

# Define local variables for easy access to configuration values
locals {
  instance_name = "test-ssh-2" # Derived from platform.instanceName in the JSON
  region        = "us-east-1"  # Derived from platform.region in the JSON
  vm_size       = "t3.micro"   # Derived from platform.vmSize in the JSON
  ami_name      = "amazon-linux-2023-19199576595" # CRITICAL: From instructions 'Actual Cloud Image Name'
}

# --- AWS Networking Data Sources ---

# Look up the default VPC in the specified region.
# This ensures that instances are deployed into an existing network environment.
data "aws_vpc" "default" {
  default = true
}

# Find all subnets within the default VPC.
# The virtual machine will be placed into one of these subnets.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- AMI Data Source ---

# Look up the custom AMI by its specific name.
# This data source finds the ID of the pre-built image to be used for the VM.
data "aws_ami" "this_ami" {
  owners      = ["self"] # Search for AMIs owned by the current AWS account
  most_recent = true     # Select the most recent AMI if multiple match the criteria

  filter {
    name   = "name"
    values = [local.ami_name] # Filter by the exact image name provided in instructions
  }
}

# --- SSH Key Pair Generation (for Linux VMs) ---

# Generate a new RSA private key for SSH access.
# This key will be used to secure access to the Linux virtual machine.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'comment' argument is forbidden for this resource type.
}

# Create an AWS Key Pair resource using the public key derived from the tls_private_key.
# This key pair is then associated with the AWS EC2 instance.
resource "aws_key_pair" "admin_key" {
  key_name   = "${local.instance_name}-key"
  public_key = tls_private_key.admin_ssh.public_key_openssh
}

# --- Security Group for the Virtual Machine ---

# Create an AWS Security Group for the virtual machine.
# This security group controls network access to and from the VM.
resource "aws_security_group" "this_sg" {
  name        = "${local.instance_name}-sg" # Name based on the instance name, suffixed with "-sg"
  description = "Security group for ${local.instance_name}"
  vpc_id      = data.aws_vpc.default.id # Associate with the default VPC

  # CRITICAL: Allow all egress traffic (all protocols, all ports, to all destinations).
  # This enables the VM to initiate outbound connections.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # Represents all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  # CRITICAL: No ingress rules are defined.
  # This implies that administrative access to the VM will be managed via other means (e.g., AWS Systems Manager).
  # The ingress block is intentionally omitted.

  tags = {
    Name = "${local.instance_name}-sg"
  }
}

# --- Virtual Machine Deployment ---

# Deploy the AWS EC2 instance (virtual machine).
# This is the primary compute resource for the deployment.
resource "aws_instance" "this_vm" {
  ami                         = data.aws_ami.this_ami.id        # Use the ID of the custom AMI found by the data source
  instance_type               = local.vm_size                   # Set the instance type (VM size) from configuration
  subnet_id                   = data.aws_subnets.default_subnets.ids[0] # Place the VM in the first available subnet of the default VPC
  associate_public_ip_address = false                             # CRITICAL: Do NOT assign a public IP address for enhanced security
  vpc_security_group_ids      = [aws_security_group.this_sg.id] # Attach the created security group
  key_name                    = aws_key_pair.admin_key.key_name   # Associate the generated SSH key pair
  iam_instance_profile        = "ssm_instance_profile"            # CRITICAL: Hardcode IAM instance profile for SSM connectivity

  tags = {
    Name = local.instance_name
  }
}

# --- Output Block: Private IP Address ---

# Expose the private IP address of the deployed virtual machine.
# This IP is used for internal network communication within the VPC.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# --- Output Block: Instance ID ---

# Expose the cloud provider's native instance ID for the virtual machine.
# This ID is a unique identifier within AWS.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = aws_instance.this_vm.id
}

# --- Output Block: Private SSH Key (Sensitive) ---

# Expose the generated private SSH key.
# CRITICAL: This output is marked as sensitive to prevent its value from being displayed in plaintext in logs.
output "private_ssh_key" {
  description = "The generated private SSH key for administrative access to the VM. This value is sensitive."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}