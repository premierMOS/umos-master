# Configure the AWS provider
provider "aws" {
  region = var.region
}

# --- Variables Block ---
# CRITICAL INSTRUCTION: All key configuration values MUST be declared as variables with default values.

variable "instance_name" {
  description = "The name of the virtual machine instance."
  type        = string
  default     = "test-patch" # From platform.instanceName
}

variable "region" {
  description = "The AWS region where the VM will be deployed."
  type        = string
  default     = "us-east-1" # From platform.region
}

variable "vm_size" {
  description = "The instance type (VM size) for the virtual machine."
  type        = string
  default     = "t3.micro" # From platform.vmSize
}

variable "custom_script" {
  description = "Optional user data script to execute on instance startup."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n" # From platform.customScript
}

variable "tenant_id" {
  description = "The unique identifier for the tenant."
  type        = string
  default     = "tenant-manager-001" # From tenantId
}

variable "image_name" {
  description = "The exact name of the custom AMI to use for the instance."
  type        = string
  default     = "amazon-linux-2023-19315310214" # CRITICAL: Specific value from instruction
}

# --- Data Sources ---

# CRITICAL AWS NETWORKING: Lookup the default VPC
data "aws_vpc" "default" {
  default = true
}

# CRITICAL AWS NETWORKING: Lookup default subnets within the default VPC
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# CRITICAL IMAGE NAME INSTRUCTION: Find the custom AMI by its exact name
data "aws_ami" "custom_image" {
  owners      = ["self"] # Custom images are owned by the account
  most_recent = true     # Ensure we get the latest if multiple exist
  filter {
    name   = "name"
    values = [var.image_name]
  }
}

# CRITICAL AWS NETWORKING & SECURITY GROUP: Data source to check for an existing shared security group
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# --- Shared Security Group (Get-or-Create Pattern) ---

# CRITICAL AWS NETWORKING & SECURITY GROUP: Conditionally create the shared security group if it doesn't exist
resource "aws_security_group" "tenant_shared_sg" {
  count = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0 # Create if no existing group found

  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for tenant ${var.tenant_id} allowing internal communication"
  vpc_id      = data.aws_vpc.default.id

  # CRITICAL: Ingress rule allowing all traffic from within the security group itself
  ingress {
    protocol  = "-1" # All protocols (TCP, UDP, ICMP)
    from_port = 0
    to_port   = 0
    self      = true # CRITICAL: FORBIDDEN 'description' argument
  }

  # CRITICAL: Egress rule allowing all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"] # CRITICAL: FORBIDDEN 'description' argument
  }

  tags = {
    Name = "pmos-tenant-${var.tenant_id}-sg"
  }
}

# CRITICAL AWS NETWORKING & SECURITY GROUP: Local variable to reference the shared security group ID
locals {
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]
}

# --- SSH Key Pair Generation ---
# CRITICAL INSTRUCTION: For Linux deployments, generate an SSH key pair.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
}

# CRITICAL INSTRUCTION: Create an AWS Key Pair resource.
resource "aws_key_pair" "admin_key" {
  key_name_prefix = "${var.instance_name}-key-" # CRITICAL: Use key_name_prefix to avoid collisions on retries
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}

# --- IAM Role and Instance Profile for SSM ---
# CRITICAL AWS SECURE CONNECTIVITY & IAM INSTRUCTIONS:

# 1. Create an IAM Role for SSM
resource "aws_iam_role" "ssm_role" {
  name_prefix        = "${var.instance_name}-ssm-role-" # CRITICAL: Use name_prefix for the role name
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
    Name = "${var.instance_name}-ssm-role"
  }
}

# 2. Attach SSM Managed Policy
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 3. Create an IAM Instance Profile
resource "aws_iam_instance_profile" "ssm_profile" {
  name_prefix = "${var.instance_name}-ssm-profile-" # CRITICAL: Use name_prefix for the instance profile name
  role        = aws_iam_role.ssm_role.name
  # CRITICAL: The 'aws_iam_instance_profile' resource does NOT support a 'description' argument.
}

# --- Primary Compute Resource ---
# CRITICAL INSTRUCTION: Name the primary compute resource "this_vm".
resource "aws_instance" "this_vm" {
  ami           = data.aws_ami.custom_image.id # CRITICAL IMAGE NAME INSTRUCTION: Use data source for AMI ID
  instance_type = var.vm_size
  key_name      = aws_key_pair.admin_key.key_name # Attach the generated key pair

  # CRITICAL AWS NETWORKING: Place instance in a default subnet
  subnet_id = data.aws_subnets.default_subnets.ids[0]

  # CRITICAL NETWORKING REQUIREMENT: Required for SSM Agent connectivity in public subnets
  associate_public_ip_address = true

  # CRITICAL AWS NETWORKING & SECURITY GROUP: Associate with the shared security group
  vpc_security_group_ids = [local.shared_sg_id]

  # CRITICAL AWS SECURE CONNECTIVITY & IAM: Attach the SSM instance profile
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  # USER DATA/CUSTOM SCRIPT: Pass custom_script as user data
  user_data_base64 = base64encode(var.custom_script) # CRITICAL: FORBIDDEN from using 'user_data'. Use 'user_data_base64'.

  tags = {
    Name = var.instance_name
  }

  # CRITICAL AWS SECURE CONNECTIVITY & IAM: Ensure policy attachment completes before creating instance
  depends_on = [
    aws_iam_role_policy_attachment.ssm_policy_attach
  ]
}

# --- Outputs Block ---

# CRITICAL INSTRUCTION: Output the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the deployed virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# CRITICAL INSTRUCTION: Output the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native ID for the virtual machine instance."
  value       = aws_instance.this_vm.id
}

# CRITICAL INSTRUCTION: Output the generated private SSH key. This output MUST be marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for accessing the instance."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true # Mark as sensitive
}