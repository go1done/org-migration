# org-governance/github/main.tf
provider "github" {
  owner = var.github_org
  # Authentication via GITHUB_TOKEN env var or GitHub App
}

variable "github_org" {
  description = "Target GitHub organization name"
  type        = string
}
