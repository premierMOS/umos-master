
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
      version = ">= 1.1.2"
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
  default = "gcp"
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


source "googlecompute" "base" {
  project_id      = var.gcp_project_id
  source_image_family = "windows-2019-core"
  image_name      = "windows-2019-${var.platform}-${var.build_id}"
  zone            = "us-central1-a"
  machine_type    = local.effective_vm_size
  disk_size       = 50
  ssh_username    = "packer"
  
  communicator = "winrm"
  winrm_insecure = true
  winrm_username = "packer"
  winrm_use_iap  = true
  
}

build {
  sources = ["source.googlecompute.base"]


}
