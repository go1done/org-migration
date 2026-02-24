# GitHub Organisation Policy Standards

All rules below are drawn directly from the organisation governance policy specification
(policy images: `Github Rulesets`, `Org settings`, `github_action`, `Team standards`).

Each rule notes its enforcement mechanism. Where multiple mechanisms apply, the primary
one is listed first.

---

## 1. Repository Settings

| Rule | Enforcement |
|------|-------------|
| Repository creation restricted to org admins only | Terraform (`members_can_create_repositories = false`) |
| Repositories may not be deleted by non-org-admin members | Shell: `apply-org-policy.sh` (`members_can_delete_repositories = false`) |
| Org members may not change repository visibility | GitHub UI: Settings > Member privileges > Repository visibility change |
| All repositories are `private` — no `internal` repositories | Terraform (`members_can_create_internal_repositories = false`) |
| Repositories must have a non-default branch named `dev` | Terraform (`github_branch` resource in `repos.tf`) |
| Repositories must have a non-default branch named `lab` | Terraform (`github_branch` resource in `repos.tf`) |
| Repositories must include an "About" description | Intake process (MyCloud portal validation) |
| Repositories must have a `README.md` at the root | GitHub Actions: `repo-compliance-check.yml` |
| New repositories must go through the MyCloud intake portal | Process requirement |
| Repository names must be all lowercase | GitHub Actions: webhook on `repository.created` |
| Repository names must use hyphens as word separators | GitHub Actions: webhook on `repository.created` |
| Repository names must only use `a-z`, `0-9`, and `-` | GitHub Actions: webhook on `repository.created` |
| Repository names must not use capital letters | GitHub Actions: webhook on `repository.created` |
| Repository names must not use consecutive hyphens (`--`) | GitHub Actions: webhook on `repository.created` |
| Repository names should be short and descriptive | Convention (intake portal guidance) |
| Repository names should NOT begin with or include an AIT number | Convention (intake portal guidance) |
| Repositories must store metadata (contact person, team name, AIT) in GitHub repository metadata | GitHub Custom Properties (`github_organization_custom_property`) |
| All repository content must use Unix line endings (`\n` only) — CRLF rejected | `.gitattributes` per repo: `* text=auto eol=lf` |

---

## 2. Branch Rules

| Rule | Enforcement |
|------|-------------|
| Default branch name must be `main` | Terraform (`github_repository.default_branch = "main"`) |
| Merges to `main` must go through an approved Pull Request | Ruleset: `baseline` (`pull_request` rule) |
| Merges to `lab` must go through an approved Pull Request | Ruleset: `lab-branch-protection` (`pull_request` rule) |
| Merges to any other branch must go through an approved Pull Request | Ruleset: `non-default-branch-pr` (`pull_request` rule) |
| `main` branch must not be deleted | Ruleset: `baseline` (`deletion` rule) |
| `lab` branch must not be deleted | Ruleset: `lab-branch-protection` (`deletion` rule) |
| No force-pushes to any protected branch | Rulesets: all (`non_fast_forward` rule) |
| Branches with the `spike` prefix must NOT be merged to any branch at any time | GitHub Actions: reject PR if source branch matches `spike/*` |
| `feature/*` branches must NOT merge directly into `main` | GitHub Actions: reject PR if source is `feature/*` and target is `main` |
| `feature/*` branches may be deleted by the branch owner at any time | Permission (no enforcement required) |
| `feature/*` branches should be deleted when merged to any non-`main` branch | GitHub Actions: delete source branch on `pull_request` closed+merged (non-main target) |
| Stale non-`main` branches should be auto-deleted ≤90 days after merge | Scheduled GitHub Actions (cron) |
| Stale non-`main` branches must be auto-deleted ≤180 days after merge | Scheduled GitHub Actions (cron) |
| Any team member with edit access may merge to any branch that is not `main` or `lab` | Ruleset: `non-default-branch-pr` (1 approval sufficient) |
| Merges to `main` restricted to the assigned merging team for the repository | GitHub UI: Rulesets > `baseline` > Bypass list (add team after team IDs are known) |

---

## 3. Branch Naming Convention

All user-created branches (except `main`, `dev`, `lab`) must follow this pattern:

```
{prefix}/{jira-key}[-description-slug]
```

| Component | Rule |
|-----------|------|
| Prefix | One of: `feature`, `release`, `hotfix`, `spike` |
| Separator | `/` (exactly one — no additional `/` characters) |
| Jira key | `[a-z]+-[0-9]+` (e.g. `ecpaws-1001`) |
| Description slug | Optional; lowercase letters, digits, hyphens only |
| Character set | `a-z`, `0-9`, `-`, `/` only |
| Consecutive hyphens | Not allowed (`--`) |
| Capital letters | Not allowed |
| Underscores or other special chars | Not allowed |

**Enforcement:** Org-level ruleset `branch-naming` (regex: `^(feature|release|hotfix|spike)/[a-z]+-[0-9]+(-[a-z0-9]+)*$`)

**Example:** `feature/ecpaws-1001-create-sandbox-vpc`

---

## 4. Pull Request Rules

| Rule | Enforcement |
|------|-------------|
| PRs into `main` require ≥2 approvals | Ruleset: `baseline` |
| PRs into `lab` require ≥2 approvals | Ruleset: `lab-branch-protection` |
| PRs into non-`main`, non-`lab` branches require ≥1 approval | Ruleset: `non-default-branch-pr` |
| Stale reviews are dismissed when new commits are pushed | Rulesets: `baseline`, `lab-branch-protection`, `non-default-branch-pr` |
| Last-push approval required on `main` and `lab` PRs | Rulesets: `baseline`, `lab-branch-protection` |
| All review threads must be resolved before merging to `main` | Ruleset: `baseline` |
| CODEOWNERS review is triggered for PRs on associated content | Ruleset: `baseline` (`require_code_owner_review = true`) |
| PRs from `spike/*` branches must be rejected from any target | GitHub Actions: reject PR if source is `spike/*` |
| PRs from `feature/*` into `main` must be rejected | GitHub Actions: reject PR if source is `feature/*` and target is `main` |
| PRs from `release/*` into `main` must be made as squash commits | GitHub Actions: validate merge method before merge |
| PRs from `feature/*` must NOT use squash commits | GitHub Actions: validate merge method before merge |
| PRs must include the Jira issue key in the title/description | Convention (Team standards); partially enforced via commit message ruleset |
| PRs should have descriptive titles addressing what changes are being made | Convention |
| PRs should include multiple bullet points when more than one change is being made | Convention |
| `CODEOWNERS` files must be co-located with the content they govern | Convention (code review process) |

---

## 5. Commit Message Rules

| Rule | Enforcement |
|------|-------------|
| Commit messages must begin with the Jira issue key followed by `: ` — e.g. `ECPAWS-1001: ` | Org ruleset: `commit-message-jira` (regex: `^[A-Za-z]+-[0-9]+: `) |
| Commit messages should be written in the imperative mood | Convention (commitlint client-side hook) |
| Commit messages should end with ` -jmp` author signature | Convention (commitlint `commit-msg` hook) |
| Commit messages should be ≤100 characters | Convention (commitlint `commit-msg` hook) |

---

## 6. Team and Access Rules

| Rule | Enforcement |
|------|-------------|
| Regular team members may NOT create new teams — org admins only | Shell: `apply-org-policy.sh` (`members_can_create_teams = false`) |
| All teams must be IdP-linked (no local membership management) | Terraform (`github_team_sync_group_mapping`) |
| AD groups are created and linked in GITHUB-CDS (external IdP) | External IdP process |
| Local management of team membership is not allowed | Org policy + drift detection via `terraform plan` in CI |

---

## 7. Fork Rules

| Rule | Enforcement |
|------|-------------|
| Forks are allowed within the same organisation only | GitHub UI: Settings > Member privileges > Forking > "Only within this organization" |
| Forks into or from other organisations may NOT be created | Same as above |
| Private repo forks are enabled (within-org workflow) | Terraform (`members_can_fork_private_repositories = true`) |

---

## 8. Repository-Specific Rulesets (Stricter Requirements)

### `aft-*` repositories

Applied by the `aft-strict` org-level ruleset:

- ≥2 approvals, stale review dismissal, last-push approval, thread resolution, CODEOWNERS review
- Three required CI status checks: `terraform-compliance`, `terraform-validate`, `opa-policy-check`
- Branch must be up-to-date before merge (strict status check policy)
- No force-pushes, no branch deletion

### `pipeline-*` repositories

Applied by the `pipeline-strict` org-level ruleset:

- ≥2 approvals, stale review dismissal, last-push approval, thread resolution, CODEOWNERS review
- Two required CI status checks: `terraform-compliance`, `repo-compliance-check`
- Branch must be up-to-date before merge
- No force-pushes, no branch deletion

---

## 9. Enforcement Summary by Mechanism

| Mechanism | Count | Notes |
|-----------|-------|-------|
| Terraform (`org-governance/github/`) | ~15 settings | Primary IaC source of truth |
| Org-level rulesets (Terraform + shell) | 7 rulesets | Applied by `apply-org-policy.sh` or Terraform |
| Shell script (`apply-org-policy.sh`) | 2 settings | `members_can_create_teams`, `members_can_delete_repositories` — not in TF provider v6 |
| GitHub UI (manual, one-time) | 3 settings | Fork restriction, visibility change, ruleset bypass actors |
| GitHub Actions workflows | ~8 rules | Source-branch restrictions, auto-delete, naming, compliance checks |
| Per-repo config (`.gitattributes`, template) | 1 rule | CRLF enforcement |
| Convention / intake process | ~8 rules | Naming guidance, PR quality, commit style |

For rules that have no automated enforcement, see the alternatives in
[`docs/not-terraform-enforceable.md`](not-terraform-enforceable.md).
