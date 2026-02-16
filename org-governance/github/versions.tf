# org-governance/github/versions.tf
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Update backend to your state storage
  backend "s3" {
    bucket         = "CHANGEME-terraform-state"
    key            = "org-governance/github/terraform.tfstate"
    region         = "CHANGEME-region"
    dynamodb_table = "CHANGEME-terraform-locks"
    encrypt        = true
  }
}
