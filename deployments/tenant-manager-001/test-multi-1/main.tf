# AWS Provider Configuration
provider "aws" {
  region = var.region
}

# Terraform Variables
variable "instance_name" {
  description = "The name of the EC2 instance."
  type        = string
  default     = "test-multi-1"
}

variable "region" {
  description = "The AWS region to deploy resources into."
  type        = string
  default     = "us-east-1"
}

variable "vm_size" {
  description = "The EC2 instance type (e.g., t3.micro)."
  type        = string
  default     = "t3.micro"
}

variable "tenant_id" {
  description = "A unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001"
}

variable "custom_script" {
  description = "User data script to execute on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# Generate an SSH key pair for Linux instances
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # The 'comment' argument is forbidden for tls_private_key
}

# Create an AWS Key Pair for EC2 access
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-"
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}

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

# Data source to check for an existing shared security group
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# Conditionally create the shared security group if it doesn't exist
resource "aws_security_group" "tenant_shared_sg" {
  count = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0

  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for tenant ${var.tenant_id}"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule: Allow all traffic from within this security group
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
    # The 'description' argument is forbidden here
  }

  # Egress rule: Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    # The 'description' argument is forbidden here
  }

  tags = {
    Name    = "pmos-tenant-${var.tenant_id}-sg"
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }
}

# Local variable to determine the actual shared security group ID to use
locals {
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]
}

# IAM Role for SSM Agent to allow the EC2 instance to communicate with AWS Systems Manager
resource "aws_iam_role" "ssm_role" {
  name_prefix        = "${var.instance_name}-ssm-role-"
  description        = "IAM role for EC2 instances to use AWS SSM"
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

# Attach the AmazonSSMManagedInstanceCore policy to the IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM Instance Profile for attaching the role to the EC2 instance
resource "aws_iam_instance_profile" "ssm_profile" {
  name_prefix = "${var.instance_name}-ssm-profile-"
  role        = aws_iam_role.ssm_role.id
  # The 'description' argument is forbidden for aws_iam_instance_profile
}

# Data source for the custom AMI based on the specified name
data "aws_ami" "custom_image" {
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "name"
    values = ["amazon-linux-2023-19245786141"]
  }
}

# Deploy the virtual machine
resource "aws_instance" "this_vm" {
  ami                            = data.aws_ami.custom_image.id
  instance_type                  = var.vm_size
  key_name                       = aws_key_pair.admin_key.key_name
  subnet_id                      = data.aws_subnets.default_subnets.ids[0]
  vpc_security_group_ids         = [local.shared_sg_id]
  associate_public_ip_address    = true # Required for SSM agent to connect in public subnets
  user_data_base64               = base64encode(var.custom_script) # user_data_base64 is used as user_data is forbidden
  iam_instance_profile           = aws_iam_instance_profile.ssm_profile.name

  tags = {
    Name    = var.instance_name
    Tenant  = var.tenant_id
    Managed = "Terraform"
  }

  # Ensure IAM role and policy attachment are complete before creating the instance
  depends_on = [aws_iam_role_policy_attachment.ssm_policy_attach]
}

# Output the private IP address of the VM
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Output the instance ID of the VM
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = aws_instance.this_vm.id
}

# Output the generated private SSH key (sensitive)
output "private_ssh_key" {
  description = "The private SSH key generated for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}