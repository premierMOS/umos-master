# AWS Provider Configuration
provider "aws" {
  region = var.region
}

# Input Variables
# These variables are automatically populated from the provided JSON configuration.
variable "instance_name" {
  description = "The name for the virtual machine instance."
  type        = string
  default     = "test-multi-2"
}

variable "region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "The AWS EC2 instance type (vmSize)."
  type        = string
  default     = "t3.micro"
}

variable "custom_script" {
  description = "User data script to execute on instance launch."
  type        = string
  default     = "#!/bin/bash\n# User data scripts are not yet supported for direct deployment.\n"
}

# CRITICAL IMAGE NAME INSTRUCTION: Look up the custom AMI
# The exact and complete cloud image name to use for lookups is 'amazon-linux-2023-19210138993'.
data "aws_ami" "custom_image" {
  filter {
    name   = "name"
    values = ["amazon-linux-2023-19210138993"]
  }

  owners      = ["self"]
  most_recent = true
}

# CRITICAL AWS NETWORKING INSTRUCTIONS: Find the default VPC
# This data source looks up the default VPC in the specified region.
data "aws_vpc" "default" {
  default = true
}

# CRITICAL AWS NETWORKING INSTRUCTIONS: Find subnets within the default VPC
# This data source retrieves all subnets associated with the default VPC.
# CRITICAL: Using 'aws_subnets' (plural) as 'aws_subnet_ids' is deprecated.
data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# FOR LINUX DEPLOYMENTS ONLY: Generate an SSH key pair for administrative access
# This resource creates an RSA private key which will be used for SSH.
resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  # CRITICAL: The 'tls_private_key' resource does NOT support a 'comment' argument.
  # It is intentionally omitted as per instructions.
}

# FOR AWS: Create an AWS Key Pair from the generated SSH public key
# This key pair is registered with AWS and linked to the EC2 instance for SSH access.
resource "aws_key_pair" "admin_key" {
  # CRITICAL: Use key_name_prefix to avoid naming collisions on retries.
  key_name_prefix = "${var.instance_name}-key-"
  public_key      = tls_private_key.admin_ssh.public_key_openssh
}

# CRITICAL AWS SECURE CONNECTIVITY & IAM: Create an IAM Role for SSM
# This role grants permissions to the EC2 instance to interact with AWS Systems Manager (SSM).
resource "aws_iam_role" "ssm_role" {
  # CRITICAL: Use name_prefix for the role name to avoid collisions on retries.
  name_prefix = "${var.instance_name}-ssm-role-"

  # CRITICAL: The role's 'assume_role_policy' MUST trust the EC2 service.
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
    Name        = "${var.instance_name}-ssm-role"
    Environment = "DevOps"
  }
}

# CRITICAL AWS SECURE CONNECTIVITY & IAM: Attach the SSM managed policy
# This attachment links the AmazonSSMManagedInstanceCore policy to the created IAM role,
# enabling necessary SSM functionalities.
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  # CRITICAL: Attach the AWS managed policy "AmazonSSMManagedInstanceCore".
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ssm_role.name
}

# CRITICAL AWS SECURE CONNECTIVITY & IAM: Create an IAM Instance Profile
# An instance profile is a container for an IAM role that you can use to pass role information
# to an EC2 instance when the instance starts.
resource "aws_iam_instance_profile" "ssm_profile" {
  # CRITICAL: Use name_prefix for the instance profile name.
  name_prefix = "${var.instance_name}-ssm-profile-"
  # CRITICAL: This resource MUST reference the 'id' of the 'aws_iam_role.ssm_role'.
  role = aws_iam_role.ssm_role.id

  tags = {
    Name        = "${var.instance_name}-ssm-profile"
    Environment = "DevOps"
  }
}

# CRITICAL AWS DEPLOYMENTS: Create a security group for the instance
# This security group controls inbound and outbound traffic for the EC2 instance.
resource "aws_security_group" "this_sg" {
  # CRITICAL: Use name_prefix to avoid naming collisions on retries.
  name_prefix = "${var.instance_name}-sg-"
  description = "Security group for ${var.instance_name} allowing egress for SSM."
  # CRITICAL: The security group MUST be associated with the default VPC.
  vpc_id      = data.aws_vpc.default.id

  # CRITICAL: The security group MUST allow all egress traffic.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  # CRITICAL: The security group MUST NOT have any 'ingress' blocks.
  # Inbound access is managed securely via AWS SSM, not direct network access.

  tags = {
    Name        = "${var.instance_name}-sg"
    Environment = "DevOps"
  }
}

# Deploy the virtual machine
# CRITICAL INSTRUCTION: Name the primary compute resource "this_vm".
resource "aws_instance" "this_vm" {
  # Use the AMI ID retrieved from the custom_image data source.
  ami           = data.aws_ami.custom_image.id
  instance_type = var.instance_type

  # CRITICAL NETWORKING REQUIREMENT:
  # To ensure connectivity for management agents like AWS SSM,
  # instances in default public subnets require a public IP address.
  associate_public_ip_address = true

  # CRITICAL AWS NETWORKING INSTRUCTIONS:
  # The 'aws_instance' resource MUST then use the ID of the first available
  # subnet from the data source for its 'subnet_id' argument.
  subnet_id = data.aws_subnets.default_subnets.ids[0]

  # CRITICAL AWS DEPLOYMENTS:
  # The 'aws_instance' resource MUST be associated with this security group.
  vpc_security_group_ids = [aws_security_group.this_sg.id]

  # FOR AWS: Attach the generated SSH key pair for initial access if needed.
  key_name = aws_key_pair.admin_key.key_name

  # CRITICAL AWS SECURE CONNECTIVITY & IAM: Attach the IAM Instance Profile.
  # This provides the instance with the necessary permissions for SSM.
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  # USER DATA/CUSTOM SCRIPT: Pass the custom script to the instance's user data.
  # CRITICAL: Use 'user_data_base64' and 'base64encode()' for AWS.
  user_data_base64 = base64encode(var.custom_script)

  # CRITICAL AWS SECURE CONNECTIVITY & IAM:
  # Explicitly wait for the IAM role and policy attachment to complete
  # to prevent race conditions during instance launch.
  depends_on = [
    aws_iam_role_policy_attachment.ssm_policy_attach
  ]

  tags = {
    Name        = var.instance_name
    Environment = "DevOps"
  }
}

# Output Block: Expose the private IP address of the created virtual machine.
output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

# Output Block: Expose the cloud provider's native instance ID.
output "instance_id" {
  description = "The cloud provider's native instance ID."
  value       = aws_instance.this_vm.id
}

# Output Block: Expose the generated private SSH key.
# CRITICAL: This output MUST be marked as sensitive.
output "private_ssh_key" {
  description = "The generated private SSH key for administrative access. Keep this secure!"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}

# Additional output for the generated public SSH key (useful for debugging/validation).
output "public_ssh_key" {
  description = "The generated public SSH key."
  value       = tls_private_key.admin_ssh.public_key_openssh
}

# Additional output for the AWS Key Pair name.
output "aws_key_pair_name" {
  description = "The name of the AWS Key Pair created and attached to the instance."
  value       = aws_key_pair.admin_key.key_name
}

# Additional output for the Security Group ID.
output "security_group_id" {
  description = "The ID of the created AWS Security Group."
  value       = aws_security_group.this_sg.id
}

# Additional output for the IAM Role Name used for SSM.
output "ssm_role_name" {
  description = "The name of the IAM Role created for SSM access."
  value       = aws_iam_role.ssm_role.name
}

# Additional output for the IAM Instance Profile Name used for SSM.
output "ssm_instance_profile_name" {
  description = "The name of the IAM Instance Profile created for SSM access."
  value       = aws_iam_instance_profile.ssm_profile.name
}