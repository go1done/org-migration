# org-governance

Terraform-managed GitHub organization settings, rulesets, teams, and AWS compliance guardrails for the dual-org migration. This repo is the single source of truth — no manual changes via the GitHub UI.

## Prerequisites

| Tool | Required | Notes |
|------|----------|-------|
| Terraform | >= 1.5.0 | IaC for GitHub + AWS providers |
| curl | yes | API calls through corporate proxy |
| python3 | yes | JSON parsing (replaces jq in some scripts) |
| cntlm | yes | Local proxy for Kerberos/SPNEGO auth |
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

Terraform's Go HTTP client cannot authenticate directly with Kerberos/SPNEGO proxies. Use **cntlm** as a local intermediary.

### 1. Install and configure cntlm

```bash
# Install (package manager or from source — no sudo? use a local build)
# Edit /etc/cntlm.conf or ~/.cntlm.conf:
Username    your.username
Domain      CORP.EXAMPLE.COM
Proxy       corporate-proxy.example.com:8080
NoProxy     localhost, 127.0.0.1, 169.254.169.254
Listen      3128
```

Generate the password hash (avoids storing plaintext):

```bash
cntlm -H -d CORP.EXAMPLE.COM -u your.username
# Paste the output PassNTLMv2 line into your cntlm.conf
```

Start cntlm:

```bash
cntlm -v  # foreground with verbose output for initial testing
cntlm      # background once working
```

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

This checks: tools installed, cntlm running, Kerberos ticket valid, proxy connectivity to `api.github.com`, token authentication, AWS credentials, and Terraform variables.

## Usage

```bash
# 1. Ensure cntlm is running and Kerberos ticket is valid
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
