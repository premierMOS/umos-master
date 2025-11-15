
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
  default = "azure"
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


source "azure-arm" "base" {
  use_azure_cli_auth = true
  build_resource_group_name = var.managed_image_rg
  managed_image_name      = "windows-2019-${var.platform}-${var.build_id}"
  managed_image_resource_group_name = var.managed_image_rg
  os_type         = "Windows"
  image_publisher = "MicrosoftWindowsServer"
  image_offer     = "WindowsServer"
  image_sku       = "2019-datacenter"
  image_version   = "latest"
  vm_size         = local.effective_vm_size
  
  communicator = "winrm"
  winrm_use_ssl = true
  winrm_insecure = true
  winrm_timeout = "10m"
  winrm_username = "packer"
  
}

build {
  sources = ["source.azure-arm.base"]


  provisioner "powershell" {
    inline = [
      "Write-Host 'Running Sysprep to generalize the image for Azure...'",
      "& $env:SystemRoot/System32/Sysprep/Sysprep.exe /oobe /generalize /shutdown /quiet"
    ]
  }

}
