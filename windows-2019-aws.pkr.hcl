
packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
    azure = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/azure"
    }
    googlecompute = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

locals {
  aws_default_vm_size   = "t3.medium"
  azure_default_vm_size = "Standard_B1s"    # Use a small, 1-core VM to avoid quota issues on new/trial accounts.
  gcp_default_vm_size   = "e2-medium"

  # Choose the default based on the platform variable
  platform_default_vm_size = var.platform == "aws" ? local.aws_default_vm_size : (var.platform == "azure" ? local.azure_default_vm_size : local.gcp_default_vm_size)

  # Use the user-provided vm_size if it's not empty, otherwise use our platform-specific default.
  effective_vm_size = var.vm_size != "" && var.vm_size != null ? var.vm_size : local.platform_default_vm_size
}

variable "build_id" {
  type    = string
  default = "local"
}

variable "platform" {
  type    = string
  default = "aws"
}

variable "vm_size" {
  type    = string
  default = "" # Default to empty string; effective size is determined in 'locals'
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "managed_image_rg" {
  type    = string
  default = "rg-packer-images"
}

variable "gcp_project_id" {
  type    = string
  default = ""
}

variable "iam_instance_profile" {
  type    = string
  default = ""
}


source "amazon-ebs" "base" {
  ami_name        = "windows-2019-${var.platform}-${var.build_id}"
  instance_type   = local.effective_vm_size
  region          = var.aws_region
  # IAM instance profile is omitted for Windows builds to prevent potential issues.
  # Packer will connect via WinRM, which does not require an instance profile.
  associate_public_ip_address = true
  source_ami_filter {
    filters = {
      name                = "Windows_Server-2019-English-Full-Base-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    most_recent = true
    owners      = ["801119661308"]
  }
  
  user_data = <<-EOT
<powershell>
# Ensure WinRM service is running, configured for HTTPS, and firewall is open.
# This is often necessary to resolve race conditions where the service isn't ready when Packer first tries to connect.
Set-ExecutionPolicy Unrestricted -Force
winrm quickconfig -q
winrm set winrm/config/service/auth '@{Basic="true"}'
netsh advfirewall firewall add rule name="WinRM-HTTPS" dir=in action=allow protocol=TCP localport=5986
</powershell>
EOT
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "15m"

}

build {
  sources = ["source.amazon-ebs.base"]

}
