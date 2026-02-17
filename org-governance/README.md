# org-governance

Terraform-managed GitHub organization settings, rulesets, teams, and AWS compliance guardrails. This repo is the single source of truth — no manual changes via the GitHub UI.

## Prerequisites

- Terraform >= 1.5.0
- `GITHUB_TOKEN` environment variable (org admin scope)
- S3 backend for state storage (bucket, DynamoDB lock table)
- AWS credentials for SCP/Config rule management

## Structure

```
github/          # GitHub org settings, rulesets, teams, repos, secrets
aws/             # AWS SCPs and Config rules
compliance/      # Compliance dashboard infrastructure
environments/    # Per-environment tfvars
```

## Usage

```bash
cd github/
export GITHUB_TOKEN="ghp_..."
export TF_VAR_github_org="your-org"
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## CHANGEME Placeholders

Search for `CHANGEME` across all `.tf` and `.tfvars` files and replace with actual values before applying:

```bash
grep -rn "CHANGEME" .
```
