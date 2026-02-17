# Creating an AWS CodeStar Connection to GitHub

This guide covers creating a CodeStar Connection (CodeConnections) from AWS to a GitHub organization. You need one connection per GitHub org.

## Prerequisites

- AWS account with admin or PowerUser access
- GitHub org admin access (to authorize the AWS Connector GitHub App)
- AWS CLI v2 installed and configured, OR access to the AWS Console

---

## Option A: AWS Console (Recommended for first-time setup)

### Step 1: Navigate to CodeConnections

1. Sign in to the AWS Console
2. Go to **Developer Tools** > **Settings** > **Connections**
   - Direct URL: `https://<region>.console.aws.amazon.com/codesuite/settings/connections`
3. Click **Create connection**

### Step 2: Select provider

1. Under **Select a provider**, choose **GitHub**
2. Enter a **Connection name** (e.g., `github-new-org` or `github-old-org`)
   - Use a descriptive name that identifies which GitHub org this connects to
3. Click **Connect to GitHub**

### Step 3: Authorize the AWS Connector GitHub App

1. A popup window opens to GitHub
2. If not already signed in, sign in to GitHub with an account that is an **admin** of the target org
3. You will see **AWS Connector for GitHub** requesting access
4. Click **Install a new app** (if this is the first connection to this org)
5. Select the **GitHub organization** you want to connect
6. Choose repository access:
   - **All repositories** (recommended for org-wide access)
   - Or **Only select repositories** (if you want to restrict)
7. Click **Install & Authorize**
8. You are returned to the AWS Console

### Step 4: Complete the connection

1. Back in the AWS Console, the GitHub App installation should appear
2. Click **Connect**
3. The connection status should change to **Available**
4. Note the **Connection ARN** — you'll need this for Terraform

### Step 5: Record the connection ARN

The ARN format is:
```
arn:aws:codeconnections:<region>:<account-id>:connection/<connection-id>
```

Copy this and add it to your Terraform config:
```hcl
# org-governance/aws/codestar-connections.auto.tfvars
codestar_connections = {
  "your-github-org" = "arn:aws:codeconnections:us-east-1:123456789012:connection/abc12345-1234-1234-1234-abc123456789"
}
```

---

## Option B: AWS CLI

### Step 1: Create the connection

```bash
aws codeconnections create-connection \
  --provider-type GitHub \
  --connection-name "github-new-org" \
  --region us-east-1
```

Output:
```json
{
  "ConnectionArn": "arn:aws:codeconnections:us-east-1:123456789012:connection/abc12345-..."
}
```

Save this ARN.

### Step 2: Complete the connection in the Console (required)

The CLI creates the connection in **Pending** status. You MUST complete the handshake in the Console:

1. Go to **Developer Tools** > **Settings** > **Connections**
2. Find your connection (status: **Pending**)
3. Click **Update pending connection**
4. Follow the GitHub authorization flow (same as Console Step 3 above)
5. Once authorized, status changes to **Available**

> **There is no way to complete the GitHub OAuth handshake purely via CLI.** The Console step is required once per connection.

### Step 3: Verify

```bash
aws codeconnections get-connection \
  --connection-arn "arn:aws:codeconnections:us-east-1:123456789012:connection/abc12345-..." \
  --region us-east-1
```

Confirm `ConnectionStatus` is `Available`.

---

## Option C: Terraform

### Step 1: Create the connection resource

```hcl
resource "aws_codestarconnections_connection" "github_new_org" {
  name          = "github-new-org"
  provider_type = "GitHub"
}

output "connection_arn" {
  value = aws_codestarconnections_connection.github_new_org.arn
}

output "connection_status" {
  value = aws_codestarconnections_connection.github_new_org.connection_status
}
```

```bash
terraform apply
```

### Step 2: Complete the connection in the Console (required)

Same as CLI — Terraform creates the connection in **Pending** status. You must complete the GitHub handshake in the Console:

1. Go to **Developer Tools** > **Settings** > **Connections**
2. Click **Update pending connection** on the new connection
3. Authorize the AWS Connector GitHub App for your org
4. Status changes to **Available**

### Step 3: Verify via Terraform

```bash
terraform refresh
terraform output connection_status
# Should output: "Available"
```

---

## Setting Up Both Connections (Dual-Org Model)

For the migration, repeat the process above twice — once per org:

| Connection | GitHub Org | Purpose |
|------------|-----------|---------|
| `github-old-org` | Old org | Repos that stay in the old org |
| `github-new-org` | New org | Repos migrated to the new org |

Then add both ARNs to Terraform:

```hcl
# org-governance/aws/codestar-connections.auto.tfvars
codestar_connections = {
  "old-org-name" = "arn:aws:codeconnections:us-east-1:123456789012:connection/aaa-111"
  "new-org-name" = "arn:aws:codeconnections:us-east-1:123456789012:connection/bbb-222"
}
```

---

## Troubleshooting

### Connection stuck in "Pending"

The GitHub OAuth handshake was not completed. Go to the Console and click **Update pending connection** to authorize.

### "Resource not accessible by integration" errors

The AWS Connector GitHub App does not have access to the repo. Fix:
1. Go to GitHub > **Settings** > **Applications** > **AWS Connector for GitHub**
2. Click **Configure**
3. Under **Repository access**, ensure the repo is included (or select **All repositories**)

### "Connection is not available" in CodePipeline

The connection exists but is not in **Available** status. Check:
```bash
aws codeconnections get-connection --connection-arn <arn>
```
If Pending, complete the handshake. If Error, delete and recreate.

### Permission denied creating connections

You need one of:
- `codeconnections:CreateConnection` permission
- Or the managed policy: `AWSCodeStarFullAccess`

Minimum IAM policy for creating connections:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "codeconnections:CreateConnection",
        "codeconnections:GetConnection",
        "codeconnections:ListConnections",
        "codeconnections:DeleteConnection",
        "codeconnections:UseConnection"
      ],
      "Resource": "*"
    }
  ]
}
```

### Cross-account connections

If your pipelines run in a different AWS account than the connections:
- Create the connection in the **pipeline account**
- Or use a cross-account IAM role with `codeconnections:UseConnection` permission on the connection ARN

---

## Verifying Both Connections Work

After setting up both connections, verify:

```bash
# List all connections
aws codeconnections list-connections --region us-east-1

# Check each connection status
aws codeconnections get-connection \
  --connection-arn "arn:aws:codeconnections:us-east-1:123456789012:connection/aaa-111"

aws codeconnections get-connection \
  --connection-arn "arn:aws:codeconnections:us-east-1:123456789012:connection/bbb-222"
```

Both should show `ConnectionStatus: Available`.

---

## Persisting in Terraform (Import After Manual Creation)

After creating connections manually and completing the GitHub handshake, import them into Terraform so they're managed as code.

### Step 1: Get your connection ARNs

```bash
aws codeconnections list-connections --region us-east-1 \
  --query 'Connections[].{Name:ConnectionName,ARN:ConnectionArn,Status:ConnectionStatus}' \
  --output table
```

Note the ARN for each connection.

### Step 2: Update tfvars with your actual values

Edit `org-governance/aws/codestar-connections.auto.tfvars`:

```hcl
github_connections = {
  "old-org-name" = {
    name = "github-old-org"    # must match the name you used in Console
    tags = {
      Purpose   = "Source code access for repos staying in old org"
      ManagedBy = "terraform"
    }
  }
  "new-org-name" = {
    name = "github-new-org"    # must match the name you used in Console
    tags = {
      Purpose   = "Source code access for repos migrated to new org"
      ManagedBy = "terraform"
    }
  }
}
```

### Step 3: Initialize Terraform

```bash
cd org-governance/aws
terraform init
```

### Step 4: Import each connection into state

```bash
# Import the old org connection
terraform import \
  'aws_codestarconnections_connection.github["old-org-name"]' \
  arn:aws:codeconnections:us-east-1:123456789012:connection/aaa-111

# Import the new org connection
terraform import \
  'aws_codestarconnections_connection.github["new-org-name"]' \
  arn:aws:codeconnections:us-east-1:123456789012:connection/bbb-222
```

Expected output for each:
```
aws_codestarconnections_connection.github["old-org-name"]: Importing...
aws_codestarconnections_connection.github["old-org-name"]: Import complete!
```

### Step 5: Verify with terraform plan

```bash
terraform plan
```

Expected: **No changes.** If Terraform shows changes, it's likely a name or tag mismatch — update your tfvars to match the existing connection exactly.

```
No changes. Your infrastructure matches the configuration.
```

### Step 6: Apply tags (if plan shows tag additions only)

If the only changes are adding tags (the manually created connection didn't have tags), that's safe:

```bash
terraform apply
```

### Step 7: Verify outputs

```bash
terraform output connection_arns
# {
#   "old-org-name" = "arn:aws:codeconnections:us-east-1:123456789012:connection/aaa-111"
#   "new-org-name" = "arn:aws:codeconnections:us-east-1:123456789012:connection/bbb-222"
# }

terraform output connection_statuses
# {
#   "old-org-name" = "AVAILABLE"
#   "new-org-name" = "AVAILABLE"
# }
```

### What Terraform manages after import

| Attribute | Managed | Notes |
|-----------|---------|-------|
| Connection name | Yes | Renaming is safe |
| Tags | Yes | Add/update/remove |
| Deletion | Protected | `prevent_destroy = true` in the resource |
| GitHub OAuth handshake | No | AWS-side only, not in Terraform state |
| Provider type | Yes | Immutable after creation |

### Alternative: Terraform 1.5+ import blocks (no CLI needed)

If you're on Terraform >= 1.5, you can use `import` blocks instead of the CLI command. Add this to a temporary file:

```hcl
# org-governance/aws/imports.tf (delete after successful import)
import {
  to = aws_codestarconnections_connection.github["old-org-name"]
  id = "arn:aws:codeconnections:us-east-1:123456789012:connection/aaa-111"
}

import {
  to = aws_codestarconnections_connection.github["new-org-name"]
  id = "arn:aws:codeconnections:us-east-1:123456789012:connection/bbb-222"
}
```

Then run:

```bash
terraform plan    # shows import + any changes
terraform apply   # performs the import
```

After apply succeeds, delete `imports.tf` — the resources are now in state.

---

## Using Connections in Pipeline Repos

After import, pipeline repos consume the connection ARNs via the `pipeline-source` module:

```hcl
# In your pipeline repo's Terraform
data "terraform_remote_state" "governance" {
  backend = "s3"
  config = {
    bucket = "your-terraform-state-bucket"
    key    = "org-governance/aws/terraform.tfstate"
    region = "us-east-1"
  }
}

# Source from a repo in the new org
module "source_app" {
  source = "git::https://github.com/new-org/org-governance.git//aws/modules/pipeline-source"

  repository_name = "my-app"
  github_org      = "new-org"
  connection_arns = data.terraform_remote_state.governance.outputs.connection_arns
}

# Source from a repo that stays in the old org
module "source_shared_modules" {
  source = "git::https://github.com/new-org/org-governance.git//aws/modules/pipeline-source"

  repository_name = "shared-terraform-modules"
  github_org      = "old-org"
  connection_arns = data.terraform_remote_state.governance.outputs.connection_arns
}

# Use in CodePipeline
resource "aws_codepipeline" "pipeline" {
  name     = "my-pipeline"
  role_arn = aws_iam_role.pipeline.arn

  stage {
    name = "Source"

    action {
      name             = "AppSource"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["app_source"]
      configuration    = module.source_app.source_action_config
    }

    action {
      name             = "SharedModulesSource"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["shared_source"]
      configuration    = module.source_shared_modules.source_action_config
    }
  }

  # ... build, deploy stages
}
```

The `github_org` parameter determines which connection ARN is used — no hardcoded ARNs anywhere in pipeline repos.
