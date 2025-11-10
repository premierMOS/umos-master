variable "instance_name" {
  description = "Name of the virtual machine instance."
  type        = string
  default     = "test-multi-2"
}

variable "region" {
  description = "AWS region where the resources will be deployed."
  type        = string
  default     = "us-east-1"
}

variable "vm_size" {
  description = "Instance type for the virtual machine."
  type        = string
  default     = "t3.micro"
}

variable "custom_script" {
  description = "User data script to execute on instance launch."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

variable "tenant_id" {
  description = "Unique identifier for the tenant, used for resource naming."
  type        = string
  default     = "tenant-manager-001"
}

# Configure the AWS provider
provider "aws" {
  region = var.region
}

# --- Data Sources ---

# Look up the default VPC for the current AWS account and region.
# This ensures that instances are deployed into the standard networking environment.
data "aws_vpc" "default" {
  default = true
}

# Discover all subnets within the default VPC.
# The instance will be placed into the first available subnet from this list.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Look up the custom AMI by its exact name as specified by the CI/CD pipeline.
# This ensures the correct hardened image is used for deployment.
data "aws_ami" "custom_image" {
  filter {
    name   = "name"
    values = ["amazon-linux-2023-19245786141"]
  }

  owners      = ["self"]
  most_recent = true
}

# Attempt to find an existing shared security group for the tenant.
# This is part of the get-or-create pattern to ensure a consistent security group across deployments.
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# --- SSH Key Pair Generation ---

# Generate a new private and public SSH key pair for secure access.
# The private key will be outputted and marked as sensitive.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create an AWS EC2 Key Pair using the generated public key.
# 'key_name_prefix' is used to avoid naming collisions on retries.
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-"
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}

# --- IAM Role for AWS Systems Manager (SSM) ---

# Create an IAM role that EC2 instances can assume.
# This role is specifically configured to allow SSM agent to communicate with the SSM service.
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
}

# Attach the AWS managed policy "AmazonSSMManagedInstanceCore" to the SSM role.
# This policy grants the necessary permissions for SSM agent functionality.
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an IAM instance profile, which is a container for an IAM role.
# This profile is attached to the EC2 instance to grant it the permissions defined in the SSM role.
resource "aws_iam_instance_profile" "ssm_profile" {
  name_prefix = "${var.instance_name}-ssm-profile-"
  role        = aws_iam_role.ssm_role.id
}

# --- Shared Security Group (Get-or-Create) ---

# Conditionally create a shared security group for the tenant if it doesn't already exist.
# This group allows instances within the same group to communicate (self-referencing ingress)
# and permits all outbound traffic.
resource "aws_security_group" "tenant_shared_sg" {
  count       = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0
  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for tenant ${var.tenant_id} allowing internal communication"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule: Allow all traffic from instances associated with this security group (self-referencing).
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Egress rule: Allow all outbound traffic to any destination.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "pmos-tenant-${var.tenant_id}-sg"
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# Local variable to determine the shared security group ID.
# It uses the ID of the existing group if found, otherwise the ID of the newly created group.
locals {
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]
}

# --- Virtual Machine Deployment ---

# Deploy the primary virtual machine instance.
# It uses the custom AMI, specified instance type, and is configured for SSM and SSH access.
resource "aws_instance" "this_vm" {
  ami                            = data.aws_ami.custom_image.id
  instance_type                  = var.vm_size
  subnet_id                      = data.aws_subnets.default_subnets.ids[0]
  associate_public_ip_address    = true # Required for SSM agent to connect from public subnets
  vpc_security_group_ids         = [local.shared_sg_id]
  key_name                       = aws_key_pair.admin_key.key_name
  user_data_base64               = base64encode(var.custom_script)
  iam_instance_profile           = aws_iam_instance_profile.ssm_profile.name

  tags = {
    Name    = var.instance_name
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }

  # Explicit dependency to ensure the IAM role policy is fully attached before the instance is launched.
  # This prevents potential race conditions where the instance tries to assume a role that isn't ready.
  depends_on = [
    aws_iam_role_policy_attachment.ssm_policy_attach
  ]
}

# --- Outputs ---

# Expose the private IP address of the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's unique ID for the virtual machine instance."
  value       = aws_instance.this_vm.id
}

# Expose the generated private SSH key.
# This output is marked as sensitive to prevent its value from being displayed in logs.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}