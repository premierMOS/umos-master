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
      version = "~> 5.0" # Specify an appropriate version constraint
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

# Configure the AWS provider with the specified region.
provider "aws" {
  region = var.region
}

# --- Variables Block ---
# Declares all input variables with default values directly from the provided JSON configuration.
# This ensures the script can be run without interactive prompts.

variable "instance_name" {
  description = "The name to assign to the virtual machine instance."
  type        = string
  default     = "test-aws" # Derived from platform.instanceName
}

variable "region" {
  description = "The AWS region where the virtual machine will be deployed."
  type        = string
  default     = "us-east-1" # Derived from platform.region
}

variable "vm_size" {
  description = "The instance type (VM size) for the virtual machine."
  type        = string
  default     = "t3.micro" # Derived from platform.vmSize
}

variable "custom_script" {
  description = "A custom script to execute on the VM after initial deployment."
  type        = string
  default     = "# Enter your post-deployment script here.\n# For Linux, it will be executed via bash.\n# For Windows, it will be executed via PowerShell.\n" # Derived from platform.customScript
}

variable "tenant_id" {
  description = "A unique identifier for the tenant, used for resource naming conventions."
  type        = string
  default     = "tenant-manager-001" # Derived from tenantId
}

# --- Locals Block ---
# Defines local values for conditional logic and constructing complex arguments.
locals {
  # Determines the security group ID to use. If an existing shared security group is found,
  # its ID is used; otherwise, the ID of the newly created security group is used.
  shared_sg_id = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? aws_security_group.tenant_shared_sg[0].id : data.aws_security_groups.existing_shared_sg.ids[0]

  # Constructs the user data script for AWS Windows instances.
  # This script ensures the SSM Agent is running, sets the administrator password,
  # and then executes any user-provided custom script.
  user_data_script = <<-EOT
  <powershell>
  # Ensure the SSM Agent service is set to automatic and start it
  Set-Service -Name "AmazonSSMAgent" -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name "AmazonSSMAgent" -ErrorAction SilentlyContinue

  # Set the administrator password using the generated random password
  $username = "Administrator"
  $password = ConvertTo-SecureString -String "${random_password.admin_password.result}" -AsPlainText -Force
  $user = Get-LocalUser -Name $username
  $user | Set-LocalUser -Password $password

  # User-provided script follows
  ${var.custom_script}
  </powershell>
  EOT
}

# --- Random Password Resource ---
# Generates a strong, random password for the local Administrator account on the Windows VM.
resource "random_password" "admin_password" {
  length         = 16
  special        = true
  override_special = "_!@#&" # Specific special characters allowed
}

# --- Data Sources for AWS Environment Configuration ---

# Looks up the default VPC in the current AWS region.
data "aws_vpc" "default" {
  default = true
}

# Finds all subnets associated with the default VPC.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Looks up the custom Windows AMI (Amazon Machine Image) using its exact name.
data "aws_ami" "custom_image" {
  most_recent = true         # Ensures the latest version of the AMI is selected
  owners      = ["self"]     # Specifies that the AMI must be owned by the current account

  filter {
    name   = "name"
    values = ["windows-2019-aws-19395304151"] # CRITICAL: Exact image name as specified in instructions
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"] # Standard virtualization type for modern EC2 instances
  }
}

# --- Shared Security Group - Get or Create Pattern ---

# Attempts to find an existing security group with a predictable name for the tenant.
data "aws_security_groups" "existing_shared_sg" {
  filter {
    name   = "group-name"
    values = ["pmos-tenant-${var.tenant_id}-sg"]
  }
}

# Conditionally creates a shared security group if it was not found by the data source.
# The 'count' meta-argument makes this resource creation conditional.
resource "aws_security_group" "tenant_shared_sg" {
  count = length(data.aws_security_groups.existing_shared_sg.ids) == 0 ? 1 : 0

  name        = "pmos-tenant-${var.tenant_id}-sg"
  description = "Shared security group for tenant ${var.tenant_id} instances (managed by Premier Managed OS)"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule: Allows all traffic (all protocols, all ports) from other instances
  # that are also associated with this security group (self-referencing).
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1" # All protocols
    self      = true # Source is the security group itself
  }

  # Egress rule: Allows all outbound traffic to any destination.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"          # All protocols
    cidr_blocks = ["0.0.0.0/0"] # All IP addresses
  }

  tags = {
    Name        = "pmos-tenant-${var.tenant_id}-sg"
    TenantId    = var.tenant_id
    ManagedBy   = "Terraform"
    Description = "Shared security group for PMOS managed instances."
  }
}

# --- AWS IAM Role and Instance Profile for SSM Connectivity ---

# Creates an IAM role that EC2 instances can assume.
# This role grants permissions to interact with other AWS services on behalf of the instance.
resource "aws_iam_role" "ssm_role" {
  # Using name_prefix for the role name to prevent collisions during retries or multiple deployments.
  name_prefix = "${var.instance_name}-ssm-role-"
  description = "IAM role for EC2 instance to enable AWS Systems Manager (SSM) agent communication."

  # Defines the trust policy, allowing the EC2 service to assume this role.
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

# Attaches the AWS managed policy for SSM to the created IAM role.
# This policy provides the necessary permissions for the SSM agent to function.
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Creates an IAM Instance Profile, which is a container for an IAM role
# that is associated with an EC2 instance.
resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.instance_name}-ssm-profile" # CRITICAL: Static name as per instructions
  role = aws_iam_role.ssm_role.name         # Associates this profile with the SSM role

  tags = {
    Name      = "${var.instance_name}-ssm-profile"
    TenantId  = var.tenant_id
    ManagedBy = "Terraform"
  }
}

# --- AWS EC2 Virtual Machine Resource ---
# Defines and deploys the virtual machine instance on AWS.
resource "aws_instance" "this_vm" {
  ami                         = data.aws_ami.custom_image.id        # Uses the ID of the found custom AMI
  instance_type               = var.vm_size                         # Specifies the EC2 instance type (VM size)
  associate_public_ip_address = true                                # CRITICAL: Required for SSM Agent connectivity in public subnets
  subnet_id                   = data.aws_subnets.default_subnets.ids[0] # Deploys into the first available default VPC subnet

  vpc_security_group_ids      = [local.shared_sg_id]                # Associates the instance with the shared security group
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name # Attaches the IAM instance profile for SSM

  # CRITICAL: User data script for Windows, including SSM agent setup and custom script execution.
  # This also includes the logic to set the administrator password.
  user_data                   = local.user_data_script

  tags = {
    Name      = var.instance_name
    TenantId  = var.tenant_id
    ManagedBy = "Terraform"
  }

  # CRITICAL: Explicit dependency to ensure the IAM instance profile is fully created
  # before the EC2 instance attempts to use it, preventing potential race conditions.
  depends_on = [
    aws_iam_instance_profile.ssm_profile
  ]
}

# --- Output Block: Private IP Address ---
# Exposes the private IP address assigned to the deployed virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# --- Output Block: Instance ID ---
# Exposes the AWS-assigned unique ID of the virtual machine instance.
output "instance_id" {
  description = "The unique cloud provider ID of the virtual machine instance."
  value       = aws_instance.this_vm.id
}

# --- Output Block: Administrator Password ---
# Exposes the randomly generated administrator password for the Windows VM.
# The 'sensitive = true' flag prevents this value from being displayed in plaintext in Terraform outputs.
output "admin_password" {
  description = "The randomly generated administrator password for the Windows VM."
  value       = random_password.admin_password.result
  sensitive   = true
}