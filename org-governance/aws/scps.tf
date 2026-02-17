# org-governance/aws/scps.tf
variable "aft_ou_id" {
  description = "AWS Organizations OU ID for AFT-managed accounts"
  type        = string
}

# Deny public S3 buckets
resource "aws_organizations_policy" "deny_public_s3" {
  name        = "deny-public-s3"
  description = "Prevent creation of public S3 buckets"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyPublicS3"
        Effect    = "Deny"
        Action    = [
          "s3:PutBucketPublicAccessBlock",
          "s3:PutAccountPublicAccessBlock"
        ]
        Resource  = "*"
        Condition = {
          StringNotEquals = {
            "s3:PublicAccessBlockConfiguration/BlockPublicAcls"       = "true"
            "s3:PublicAccessBlockConfiguration/BlockPublicPolicy"     = "true"
            "s3:PublicAccessBlockConfiguration/IgnorePublicAcls"      = "true"
            "s3:PublicAccessBlockConfiguration/RestrictPublicBuckets" = "true"
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_public_s3" {
  policy_id = aws_organizations_policy.deny_public_s3.id
  target_id = var.aft_ou_id
}

# Deny leaving the organization
resource "aws_organizations_policy" "deny_leave_org" {
  name        = "deny-leave-org"
  description = "Prevent accounts from leaving the organization"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyLeaveOrg"
        Effect   = "Deny"
        Action   = "organizations:LeaveOrganization"
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_org" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = var.aft_ou_id
}

# Require encryption at rest
resource "aws_organizations_policy" "require_encryption" {
  name        = "require-encryption-at-rest"
  description = "Require encryption on EBS volumes and RDS instances"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyUnencryptedEBS"
        Effect   = "Deny"
        Action   = "ec2:CreateVolume"
        Resource = "*"
        Condition = {
          Bool = {
            "ec2:Encrypted" = "false"
          }
        }
      },
      {
        Sid      = "DenyUnencryptedRDS"
        Effect   = "Deny"
        Action   = "rds:CreateDBInstance"
        Resource = "*"
        Condition = {
          Bool = {
            "rds:StorageEncrypted" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "require_encryption" {
  policy_id = aws_organizations_policy.require_encryption.id
  target_id = var.aft_ou_id
}
