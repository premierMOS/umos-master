
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
  default = "t3.medium" # A reasonable default
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


source "azure-arm" "base" {
  managed_image_name      = "windows-2019-${var.platform}-${var.build_id}"
  managed_image_resource_group_name = var.managed_image_rg
  os_type         = "Windows"
  source_image_reference = {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-datacenter"
    version   = "latest"
  }
  vm_size         = var.vm_size
  
  communicator = "winrm"
  winrm_use_ssl = true
  winrm_insecure = true
  winrm_timeout = "10m"
  winrm_username = "packer"
  
}

build {
  sources = ["source.azure-arm.base"]

}
