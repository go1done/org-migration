# org-governance/aws/versions.tf
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "CHANGEME-terraform-state"
    key            = "org-governance/aws/terraform.tfstate"
    region         = "CHANGEME-region"
    dynamodb_table = "CHANGEME-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
