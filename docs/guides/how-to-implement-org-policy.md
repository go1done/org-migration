# How to Implement Org Policy — Sequence and Phases

This document describes the correct sequence for applying org governance policy
to the new GitHub org. Steps are ordered by dependency — later steps cannot
proceed until earlier steps are complete.

Related docs:
- docs/org-policy-gaps.md — full list of gaps and enforcement mechanisms
- docs/not-terraform-enforceable.md — why each item cannot be done via Terraform

---

## Phase 1 — Prerequisites (before any policy work)

These must be true before any phase below can start.

- [ ] New GitHub org exists
- [ ] GITHUB_TOKEN available with `admin:org` scope
- [ ] Terraform backend configured (S3 bucket + DynamoDB table)
- [ ] `CHANGEME` values filled in across all `.tf` and `.tfvars` files
- [ ] Org admin or owner access confirmed

---

## Phase 2 — Terraform apply (org-governance/github)

Applies all settings the GitHub Terraform provider v6 supports.

```
cd org-governance/github
terraform init
terraform plan
terraform apply
```

What this covers:
- Org member privilege settings (default repo permission, fork policy, signoff)
- Security defaults for new repositories (Dependabot, secret scanning, GHAS)
- 7 org-level branch/commit rulesets:
  1. baseline              — main branch: 2 approvals, status checks, no force-push
  2. lab-branch-protection — lab branch: 2 approvals, no force-push
  3. non-default-branch-pr — all other branches: 1 approval
  4. branch-naming         — Jira-prefixed slug pattern
  5. commit-message-jira   — Jira key prefix on every commit
  6. aft-strict            — aft-* repos: 2 approvals + 3 required checks
  7. pipeline-strict       — pipeline-* repos: 2 approvals + 2 required checks
- Team definitions and IdP group mappings
- Terraform-managed repositories (dev/lab branches included via github_branch resources)

Prerequisite: Phase 1 complete.

---

## Phase 3 — apply-org-policy.sh (non-Terraform API settings)

Applies settings the Terraform provider cannot set.

```
export GITHUB_TOKEN="ghp_your_token"
cd migration-tooling/scripts
./apply-org-policy.sh <org-name>
```

What this covers (on top of Terraform):
- members_can_create_teams = false      [NON-TF field]
- members_can_delete_repositories = false [NON-TF field]

Note: if either field is not accepted by the API (GHEC enterprise policy may
override it), follow the UI fallback printed by the script.

Prerequisite: Phase 1 complete. Can run in parallel with Phase 2.

---

## Phase 4 — GitHub UI manual steps

Settings with no REST API support — must be done in the GitHub UI by an org admin.

- [ ] Fork restriction: Settings > Member privileges > Forking
        → "Only within this organization"
- [ ] Repo visibility change: Settings > Member privileges > Repository visibility change
        → disable for members
- [ ] Team creation: Settings > Member privileges > Team creation
        → "Only organization owners" (if greyed out: Enterprise Settings > Policies > Teams)
- [ ] Repo deletion: Settings > Member privileges > Repository deletion and transfer
        → disable for members (if greyed out: Enterprise Settings > Policies > Member privileges)
- [ ] Baseline ruleset bypass list: Settings > Rules > Rulesets > baseline > Bypass list
        → add merging team once team IDs are known

Prerequisite: Phase 1 complete. Can run in parallel with Phases 2 and 3.

---

## Phase 5 — GHEC Repository Policy (repo naming)

Blocks repo creation if the name does not match the convention.
Requires org owner or enterprise admin. Public preview feature.

- [ ] Navigate to: github.com/organizations/{org}/settings/repository_policies
        (or Enterprise Settings > Repository policies for enterprise-wide enforcement)
- [ ] New policy > Add restriction > Restrict names
- [ ] Pattern (RE2): ^[a-z0-9]+(-[a-z0-9]+)*$
- [ ] Negate: off (names must match)
- [ ] Enforcement: Active
- [ ] Save

Prerequisite: Phase 1 complete. Can run in parallel with other phases.

---

## Phase 6 — Create org-shared-workflows repo

Create the central repo that will hold all GitHub Actions enforcement workflows.

- [ ] Create repo: org-shared-workflows (private, in new org)
- [ ] Add github_branch resources for dev and lab in org-governance/github/repos.tf
        and re-run terraform apply (Phase 2)
- [ ] Confirm repo is internal/private (visibility must match or be broader than target repos
        for required workflows to function)

Prerequisite: Phase 2 complete (so repo can be Terraform-managed).

---

## Phase 7 — Write and commit workflow files

Write each workflow file to org-shared-workflows. All files must include
on: pull_request (not only on: workflow_call) to be triggered by the ruleset engine.

Files to create:

| File | Rule enforced | Trigger | Blocks merge? |
|------|--------------|---------|---------------|
| `.github/workflows/spike-merge-block.yml` | spike/* cannot merge anywhere | pull_request | yes |
| `.github/workflows/branch-merge-policy.yml` | feature/* cannot merge to main; feature/* auto-deleted after merge to non-main | pull_request + pull_request closed | yes (block) + no (delete) |
| `.github/workflows/merge-method-audit.yml` | release→main must squash; feature must not squash | pull_request closed | no — post-merge audit only |
| `.github/workflows/stale-branch-cleanup.yml` | Stale branches deleted after 90/180 days | schedule (cron weekly) | no — scheduled cleanup |
| `.github/workflows/repo-compliance-scan.yml` | Every repo has dev and lab branches (non-TF repos) | schedule (cron weekly) | no — files compliance issue |

Files to update:

| File | Change needed |
|------|--------------|
| `.github/workflows/repo-compliance-check.yml` | Add on: pull_request trigger (currently workflow_call only); add README.md check step |

Notes:
- branch-merge-policy.yml handles both the merge block and the post-merge auto-delete
  for feature branches — two jobs in one file, different activity types
- delete_branch_on_merge = true is already set as default in repos.tf; the auto-delete
  job in branch-merge-policy.yml only covers non-Terraform repos where that setting
  may not be enabled
- stale-branch-cleanup.yml and repo-compliance-scan.yml use on: schedule — they cannot
  be registered as ruleset required workflows; they just run on the org-shared-workflows
  repo itself on a schedule

Prerequisite: Phase 6 complete.

---

## Phase 8 — Test workflows on canary repo

Before registering any workflow as a required check org-wide, test it on a single
non-critical repo.

- [ ] For each pull_request workflow: open a test PR that should fail, confirm it fails;
        open a passing PR, confirm it passes
- [ ] For each schedule workflow: trigger manually via workflow_dispatch, confirm output

Prerequisite: Phase 7 complete.

---

## Phase 9 — Register pull_request workflows as org required (via rulesets)

Register each PR-blocking workflow as a required workflow in an org ruleset.
Requires org owner or custom role with "Manage organization ref update rules and rulesets".

For each workflow:
```
Org Settings → Rules → Rulesets → New ruleset
→ Target: All repositories (exclude migration-tooling and org-shared-workflows itself)
→ Add rule → "Require workflows to pass before merging"
→ Repo: org-shared-workflows
→ Workflow file: .github/workflows/<name>.yml
→ Enforcement: evaluate first, then active
```

Workflows to register:
- [ ] spike-merge-block.yml
- [ ] branch-merge-policy.yml  (the merge-block job only; delete job runs post-merge)
- [ ] repo-compliance-check.yml (after on: pull_request trigger is added)

Workflows NOT registered in rulesets (scheduled — they run independently):
- stale-branch-cleanup.yml
- repo-compliance-scan.yml
- merge-method-audit.yml  (post-merge, not a blocking check)

Prerequisite: Phase 8 complete.

---

## Summary

```
Phase 1  Prerequisites
    ↓
Phase 2  terraform apply          ──┐
Phase 3  apply-org-policy.sh      ──┤ can run in parallel
Phase 4  GitHub UI manual steps   ──┤
Phase 5  GHEC repo naming policy  ──┘
    ↓
Phase 6  Create org-shared-workflows repo
    ↓
Phase 7  Write workflow files
    ↓
Phase 8  Test on canary repo
    ↓
Phase 9  Register workflows in org rulesets
```
