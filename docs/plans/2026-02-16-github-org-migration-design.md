# GitHub Org Migration Design — AFT & Pipeline Repos

**Date:** 2026-02-16
**Approach:** Phased Migration with Policy-First Foundation (Approach B)

## Context

- **Source org:** Partially governed (inconsistent branch protection, CODEOWNERS)
- **Target org:** GitHub Enterprise Cloud — full compliance suite + custom policies
- **Repos:** 15+ repos — standard AFT structure + custom modules + pipeline repos
- **Git history:** Preserve full history (all branches, tags, commits)
- **CI/CD:** Tightly coupled to source org (hardcoded URLs, org-level secrets)
- **Automation:** Terraform (GitHub provider) for all org/repo configuration

---

## Section 1: Foundation — Terraform Org Governance Layer

Built **before any repo is migrated** in a dedicated `org-governance` repo.

### 1.1 Organization Settings

- Default repo permissions: read-only for members
- Two-factor authentication required
- Verified domains
- SAML SSO configuration (if applicable)
- IP allow list (if applicable)
- Audit log streaming to S3/CloudWatch

### 1.2 Organization Rulesets

Org-level rulesets targeting repos by naming pattern:

| Pattern | Rules |
|---------|-------|
| `aft-*` | Require PR, 2 reviewers, signed commits, status checks, no force push, no deletion |
| `pipeline-*` | Same as `aft-*` + require CODEOWNERS approval |
| `*` (baseline) | Require PR, 1 reviewer, secret scanning enabled |

### 1.3 Teams & Access

- Terraform-managed team structure with role-based access
- Teams mapped to AFT functional areas: `aft-platform`, `aft-customizations`, `pipeline-admins`
- Repository access granted via team membership, not individual permissions

### 1.4 Repository Templates

Terraform creates repo templates with:

- Standard `.github/` directory (CODEOWNERS, PR templates, issue templates)
- Pre-configured GitHub Actions workflow stubs
- `.gitignore`, `SECURITY.md`, `LICENSE`

### 1.5 Security & Compliance

- Secret scanning enabled org-wide (with push protection)
- Dependabot enabled org-wide
- Code scanning (CodeQL) default setup for Terraform/HCL repos
- Custom security advisories policy

---

## Section 2: Migration Waves

### Wave 0 — Pre-Migration Prep

**Inventory & Audit:**
- Script to enumerate all source org repos: names, visibility, default branches, branch protection rules, secrets, webhooks, deploy keys
- Map all CI/CD references to source org (grep across all repos for org name, URLs, hardcoded paths)
- Document all org-level secrets and Actions variables that need recreating
- Identify cross-repo dependencies (e.g., Terraform module sources referencing `git::https://github.com/old-org/...`)

**Access Setup:**
- Create a GitHub App or PAT in both orgs for migration tooling
- Invite team members to new org (or configure SAML SSO provisioning)
- Set up the `org-governance` Terraform repo and apply the foundation from Section 1

### Wave 1 — Canary Migration (2-3 low-risk repos)

Pick 2-3 repos that are least coupled — standalone helper modules or documentation repos.

**Per-repo migration steps:**
1. `git clone --mirror` from source org
2. Create repo in target org via Terraform (ensures correct settings)
3. `git push --mirror` to target org
4. Verify: branch protection via org ruleset, CODEOWNERS active, secret scanning enabled
5. Update CI/CD references in the repo
6. Run CI/CD end-to-end in the new org
7. Archive source repo (read-only + deprecation notice)

**Validation checklist:**
- Org rulesets applied correctly
- PR workflow enforced (test with dummy PR)
- Secret scanning catching test secrets
- Dependabot PRs created
- CI/CD passing

### Wave 2 — AFT Customization Repos

Migration order (respects dependency chain):
1. `aft-global-customizations`
2. `aft-account-customizations`
3. `aft-account-provisioning-customizations`

**Additional steps:**
- Update Terraform module source URLs from `old-org` to `new-org`
- Update `terraform.tf` backend configs if they reference org-specific paths
- Update AFT pipeline references (CodePipeline/CodeBuild source configs in AWS)
- Validate `terraform plan` produces no unexpected changes

### Wave 3 — AFT Core + Account Request

1. `aft-account-request`
2. Any AFT root/bootstrap modules

**Safeguards:**
- Schedule during a change window (no active account provisioning)
- Run `terraform plan` in AFT management account before and after
- Keep source repos accessible (read-only) for 2 weeks as rollback

### Wave 4 — Pipeline Repos

**Steps:**
- Bulk find-and-replace of source org references
- Recreate org-level Actions secrets and variables via Terraform
- Update external integrations (CodePipeline source connections, webhooks, Slack)
- Migrate GitHub Actions self-hosted runner configurations if applicable

### Wave 5 — Cleanup

- Archive all source org repos (read-only + deprecation notice)
- Remove old org access for team members (after grace period)
- Delete migration PATs/GitHub App
- Final audit: `terraform plan` on `org-governance` confirms zero drift

---

## Section 3: Custom Policy Enforcement

### 3.1 Policy-as-Code Framework

Dedicated repo: `org-policies`

**OPA/Rego policies** for Terraform plan validation:
- Enforce tagging standards on all AWS resources
- Block prohibited resource types (no public S3 buckets, no wide IAM wildcards)
- Enforce AFT naming conventions on accounts
- Require encryption-at-rest on all storage resources

**Conftest** integration for OSS Terraform (or **Sentinel** if using TFC/TFE).

### 3.2 GitHub Actions Reusable Workflows

Dedicated repo: `org-shared-workflows`

| Workflow | Purpose |
|----------|---------|
| `terraform-compliance.yml` | Runs OPA/Conftest against `terraform plan` output |
| `repo-compliance-check.yml` | CODEOWNERS exists, no secrets in code, `terraform fmt`, `terraform validate`, tflint |
| `drift-detection.yml` | Scheduled `terraform plan` with alerting on drift |
| `migration-helper.yml` | Used during migration waves (temporary) |

### 3.3 Org-Level Compliance Dashboard

Scheduled GitHub Action in `org-governance`:
- Queries all repos via GitHub API
- Checks compliance baseline (rulesets, scanning, CODEOWNERS, workflows)
- Outputs JSON + markdown compliance report
- Posts to Slack/Teams or creates Issues for non-compliant repos

### 3.4 SCP Guardrails (AWS side)

Managed in `org-governance` alongside GitHub Terraform:
- AWS Organizations SCPs applied to AFT-managed OUs
- Preventive controls (deny actions that bypass compliance)
- Detective controls via AWS Config rules

---

## Section 4: Repo Structure

```
new-org/
├── org-governance/              # Terraform — GitHub org settings + AWS SCPs
│   ├── github/
│   │   ├── main.tf
│   │   ├── org-settings.tf
│   │   ├── rulesets.tf
│   │   ├── teams.tf
│   │   ├── repos.tf
│   │   ├── secrets.tf
│   │   └── templates.tf
│   ├── aws/
│   │   ├── scps.tf
│   │   └── config-rules.tf
│   ├── compliance/
│   │   └── dashboard.tf
│   └── environments/
│       ├── prod.tfvars
│       └── staging.tfvars
│
├── org-policies/                 # OPA/Rego + Conftest policies
│   ├── policies/
│   │   ├── tagging.rego
│   │   ├── encryption.rego
│   │   ├── iam.rego
│   │   ├── networking.rego
│   │   └── naming.rego
│   ├── tests/
│   │   └── *_test.rego
│   └── conftest.toml
│
├── org-shared-workflows/         # Reusable GitHub Actions
│   └── .github/workflows/
│       ├── terraform-compliance.yml
│       ├── repo-compliance-check.yml
│       ├── drift-detection.yml
│       └── migration-helper.yml
│
├── migration-tooling/            # Temporary — deleted after migration
│   ├── scripts/
│   │   ├── inventory.sh
│   │   ├── migrate-repo.sh
│   │   ├── bulk-migrate.sh
│   │   ├── find-org-refs.sh
│   │   └── validate-migration.sh
│   └── config/
│       ├── repo-manifest.yaml
│       └── secrets-mapping.yaml
│
├── aft-account-request/
├── aft-account-customizations/
├── aft-global-customizations/
├── aft-account-provisioning-customizations/
├── pipeline-*/
└── ...
```

**Key decisions:**
- `org-governance` is the single source of truth — no manual GitHub UI changes
- Repos are created by Terraform before migration — rulesets applied before code lands
- `migration-tooling` is ephemeral — archived/deleted after all waves complete
- Policies are separate from governance — independently versioned
- Shared workflows avoid CI duplication across repos

---

## Section 5: Migration Execution Flow

### 5.1 Per-Repo Sequence

1. **Pre-flight:** Verify target repo exists (created by Terraform), rulesets active, team access provisioned
2. **Mirror:** `git clone --mirror` from source, `git push --mirror` to target
3. **Reference update:** Scan for old org references, automated replacement, flag manual review items, commit on migration branch
4. **Validation:** Open PR triggering compliance workflows — fmt, validate, plan, OPA checks, secret scan, CODEOWNERS review
5. **Post-migration:** Merge PR, verify CI/CD end-to-end, archive source repo, update manifest status

### 5.2 Bulk Orchestration

`repo-manifest.yaml` drives wave execution:

```yaml
repos:
  - name: aft-helper-module
    wave: 1
    status: pending
    source: old-org/aft-helper-module
    target: new-org/aft-helper-module
    type: module
    ci_coupled: false

  - name: aft-global-customizations
    wave: 2
    status: pending
    source: old-org/aft-global-customizations
    target: new-org/aft-global-customizations
    type: aft-customization
    ci_coupled: true
    depends_on:
      - aft-helper-module
```

### 5.3 Rollback Plan

- Source repos are never modified until the archive step
- Failed wave: delete target repo via `terraform destroy`, investigate, re-run
- No impact to other waves or already-migrated repos
