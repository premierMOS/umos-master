
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
  associate_public_ip_address = true
  subnet_filter {
    filters = {
      "map-public-ip-on-launch" = "true"
    }
    random = true
  }
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
# Generate a self-signed certificate for WinRM HTTPS
$cert = New-SelfSignedCertificate -DnsName "packer" -CertStoreLocation "cert:\LocalMachine\My"
# Create the WinRM HTTPS listener
winrm create winrm/config/Listener?Address=*+Transport=HTTPS @{Hostname="packer"; CertificateThumbprint="$($cert.Thumbprint)"}
# Open the firewall port for WinRM HTTPS
netsh advfirewall firewall add rule name="WinRM-HTTPS" dir=in action=allow protocol=TCP localport=5986
# Configure WinRM service for Packer
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
# Signal Packer that setup is complete (optional but good practice)
New-Item -Path C:\Temp -ItemType Directory -ErrorAction SilentlyContinue
Set-Content -Path "C:\Temp\packer-ready.txt" -Value "ready"
</powershell>
EOT
  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_username = "Administrator"
  winrm_port     = 5986
  winrm_timeout  = "20m"

}

build {
  sources = ["source.amazon-ebs.base"]

}
