# org-governance

Terraform-managed GitHub organization settings, rulesets, teams, and AWS compliance guardrails for the dual-org migration. This repo is the single source of truth — no manual changes via the GitHub UI.

## Prerequisites

| Tool | Required | Notes |
|------|----------|-------|
| Terraform | >= 1.5.0 | IaC for GitHub + AWS providers |
| curl | yes | API calls through corporate proxy |
| python3 | yes | JSON parsing (replaces jq in some scripts) |
| px-proxy | yes | Python-based local proxy for Kerberos/SPNEGO auth |
| klist | recommended | Verify Kerberos ticket validity |
| aws CLI | for `aws/` module | SCP and Config rule management |

### Tooling constraints

| Tool | Status | Reason |
|------|--------|--------|
| `gh` CLI | available but limited | Token scopes may restrict some operations |
| `jq` | available | Used in workflows and some scripts |
| Kerberos proxy | required | `api.github.com` blocked without proxy |

## Structure

```
github/          # GitHub org settings, rulesets, teams, repos, secrets
aws/             # AWS SCPs, Config rules, CodeStar Connections
  modules/       # Reusable modules (pipeline-source)
scripts/         # Environment validation tooling
proxy-env.template  # Proxy + credentials template
```

## Corporate proxy setup

Terraform's Go HTTP client cannot authenticate directly with Kerberos/SPNEGO proxies. Use **px-proxy** (Python-based, no additional software required) as a local intermediary.

### 1. Install and start px-proxy

```bash
# Install via pip (user-level, no sudo needed)
pip install --user px-proxy

# Start px-proxy (listens on 127.0.0.1:3128 by default)
px --proxy &

# Or with explicit corporate proxy:
px --proxy --server corporate-proxy.example.com:8080 &
```

px-proxy automatically uses your Kerberos ticket for SPNEGO authentication.

### 2. Configure environment

```bash
cp proxy-env.template proxy-env.sh
# Edit proxy-env.sh — fill in GITHUB_TOKEN, TF_VAR_github_org, etc.
source proxy-env.sh
```

`proxy-env.sh` is gitignored (contains tokens).

### 3. Validate

```bash
./scripts/check-prerequisites.sh
```

This checks: tools installed, px-proxy running, Kerberos ticket valid, proxy connectivity to `api.github.com`, token authentication, AWS credentials, and Terraform variables.

## Usage

```bash
# 1. Ensure px-proxy is running and Kerberos ticket is valid
kinit your.username@CORP.EXAMPLE.COM

# 2. Load environment
source proxy-env.sh

# 3. Validate prerequisites
./scripts/check-prerequisites.sh

# 4. Apply GitHub settings
cd github/
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 5. Apply AWS guardrails (separate state)
cd ../aws/
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## CHANGEME placeholders

Search for `CHANGEME` across all `.tf` and `.tfvars` files and replace with actual values before applying:

```bash
grep -rn "CHANGEME" .
```

Key values to populate:
- S3 backend bucket, region, DynamoDB table (in `versions.tf`)
- GitHub org name (in `proxy-env.sh` and tfvars)
- AFT OU IDs (in `aws/` tfvars)
- Team memberships (in `github/teams.tf`)
