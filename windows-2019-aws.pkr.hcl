
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
  default = "aws"
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


source "amazon-ebs" "base" {
  ami_name        = "windows-2019-${var.platform}-${var.build_id}"
  instance_type   = var.vm_size
  region          = var.aws_region
  source_ami_filter {
    filters = {
      name                = "Windows_Server-2019-English-Full-Base-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    most_recent = true
    owners      = ["801119661308"]
  }
  ssh_username = "Administrator"
  
  communicator = "winrm"
  winrm_use_ssl = true
  winrm_insecure = true
  winrm_timeout = "10m"
  winrm_username = "Administrator"
  
}

build {
  sources = ["source.amazon-ebs.base"]

}
