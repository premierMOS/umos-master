provider "aws" {
  region = "us-east-1"
}

resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
  comment   = "admin@example.com" # A descriptive comment for the key
}

resource "aws_key_pair" "admin_key" {
  key_name   = "admin-key-for-test-neil31"
  public_key = tls_private_key.admin_ssh.public_key_openssh

  tags = {
    Name = "admin-key-for-test-neil31"
  }
}

data "aws_ami" "this_ami" {
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu-20-04-19182851935"]
  }
  # No additional filters are specified, assuming the name is sufficient
  # to find the unique AMI within the 'self' owner account.
}

resource "aws_security_group" "allow_ssh" {
  name        = "allow_ssh_test_neil31"
  description = "Allow SSH inbound traffic"
  # Assuming default VPC. If a specific VPC is needed, add vpc_id argument.

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # WARNING: This allows SSH from anywhere. Restrict in production.
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_ssh_test_neil31"
  }
}

resource "aws_instance" "this_vm" {
  ami           = data.aws_ami.this_ami.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.admin_key.key_name
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]

  # For Linux, no specific username needed, default is often 'ubuntu' or 'ec2-user'
  # depending on the AMI. The SSH key handles authentication.

  tags = {
    Name = "test-neil31"
  }
}

output "private_ip" {
  description = "The private IP address of the virtual machine."
  value       = aws_instance.this_vm.private_ip
}

output "private_ssh_key" {
  description = "The private SSH key generated for accessing the VM."
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}