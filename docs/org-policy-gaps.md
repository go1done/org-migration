# Org Policy Gaps — Manual Follow-up Required

Rules from policy images NOT applied by apply-org-policy.sh.
Each item requires a manual step or a separate automation.

Legend: [GA]=GitHub Actions  [EP]=Enterprise Policy  [UI]=GitHub UI  [REPO]=per-repo config  [STYLE]=convention

---

## Delivery: how [GA] workflows apply to all repos

Workflows live in org-shared-workflows and are registered as org-level required workflows
via org rulesets. The old Actions > Required Workflows UI was removed in October 2023.
Current path:

  Org Settings → Rules → Rulesets → New ruleset
  → Add rule → "Require workflows to pass before merging"
  → Select repo: org-shared-workflows, workflow file path

Requires org owner or custom role with "Manage organization ref update rules and rulesets".

IMPORTANT — workflow trigger requirement: workflows registered as ruleset required workflows
must have on: pull_request in the file itself to be triggered by the ruleset engine. A
workflow with only on: workflow_call will not fire. Each [GA] workflow below must include
on: pull_request (plus on: workflow_call if also used as a reusable workflow).

---

## "Github Rulesets"

**[GA] spike/* branches cannot merge anywhere**
→ Trigger: on: pull_request (all target branches)
→ Check: fail if github.head_ref starts with spike/
→ Blocks merge: yes — required status check
→ Workflow: org-shared-workflows/.github/workflows/spike-merge-block.yml

**[GA] feature/* branches cannot merge directly to main**
→ Trigger: on: pull_request (target: main only via jobs condition)
→ Check: fail if github.head_ref starts with feature/ and github.base_ref is main
→ Blocks merge: yes — required status check
→ Workflow: org-shared-workflows/.github/workflows/branch-merge-policy.yml

**[GA] release→main PRs must use squash; feature PRs must NOT squash**
→ CANNOT block merge — merge method is chosen at click-time after all status checks
  pass; no pre-merge check can intercept it.
→ Enforcement: post-merge audit only
→ Trigger: on: pull_request types: [closed]
→ Check: count parent commits on merge SHA (squash=1 parent, merge commit=2 parents);
  file a compliance issue if method does not match source branch type
→ Workflow: org-shared-workflows/.github/workflows/merge-method-audit.yml

**[UI] Merges to main restricted to assigned merging team only**
→ Add bypass actors to 'baseline' ruleset once team IDs are known:
  GitHub UI: Rulesets > baseline > Bypass list > add team

---

## "Org settings"

**[UI] Forks restricted to same org only**
→ GitHub UI: Settings > Member privileges > Forking
           Select 'Only within this organization'

**[UI] Members cannot change repo visibility**
→ GitHub UI: Settings > Member privileges > Repository visibility change

**[UI] Members cannot create teams (members_can_create_teams)**
→ GitHub UI: Settings > Member privileges > Team creation
           Uncheck 'Allow members to create teams'
→ If greyed out: set at Enterprise Settings > Policies > Teams

**[UI] Members cannot delete repositories (members_can_delete_repositories)**
→ GitHub UI: Settings > Member privileges > Repository deletion and transfer
           Uncheck 'Allow members to delete or transfer repositories'
→ If greyed out: set at Enterprise Settings > Policies > Member privileges

**[GA] feature/* branches auto-deleted after merge to non-main branch**
→ Trigger: on: pull_request types: [closed], source=feature/*, target≠main
→ Action: DELETE /repos/{repo}/git/refs/heads/{branch} via GitHub API
→ Note: delete_branch_on_merge in repos.tf is binary (any merge, any target);
  this workflow adds the per-target condition Terraform cannot express
→ Workflow: org-shared-workflows/.github/workflows/branch-merge-policy.yml

**[GA] Stale branches auto-deleted after 90/180 days**
→ Trigger: on: schedule (cron, weekly) — not a ruleset required workflow
→ Check: list all branches, skip main/dev/lab, compute age of last commit
→ Thresholds: feature/* and release/* → 90 days; all others → 180 days
→ Action: delete branch; exempt main, dev, lab unconditionally
→ Workflow: org-shared-workflows/.github/workflows/stale-branch-cleanup.yml

---

## "github_action"

**[EP] Repository naming convention (lowercase, hyphens, a-z0-9 only)**
→ Covered by GHEC org/enterprise Repository Policy (public preview) — no workflow needed
→ Pattern (RE2): ^[a-z0-9]+(-[a-z0-9]+)*$
→ Config: Org Settings → Rules → Repository policies → New policy → Restrict names
  (path may vary; navigate to github.com/organizations/{org}/settings/repository_policies)
→ Blocks repo creation outright if name does not match

**[GA] Every repo must have a README.md**
→ Trigger: on: pull_request — must be added to repo-compliance-check.yml
  (current file uses on: workflow_call only; on: pull_request must be added before
  it can be registered as a ruleset required workflow — see delivery note above)
→ Check: fail if README.md absent at repo root
→ Blocks merge: yes — required status check
→ Workflow: org-shared-workflows/.github/workflows/repo-compliance-check.yml

**[GA] Every repo must have dev and lab branches**
→ Two enforcement paths:
  1. Terraform-managed repos: add github_branch resources for dev and lab in repos.tf
     (enforced at terraform apply — declarative, strongest guarantee)
  2. All repos (including portal-created): scheduled scan workflow
     Trigger: on: schedule (cron, weekly) — not a ruleset required workflow
     Check: GET /repos/{repo}/branches/{branch} → 404 means missing
     Action: file compliance issue in org-governance repo
→ Workflow: org-shared-workflows/.github/workflows/repo-compliance-scan.yml
  (separate from stale-branch-cleanup.yml — different concern and trigger)

**[REPO] Unix line endings only (CRLF rejected)**
→ Add .gitattributes to every repo template:
  * text=auto eol=lf

---

## "Team standards"

**[STYLE] Commit messages: imperative mood, ≤100 chars, end with ' -jmp'**
→ commitlint client-side hook (commit-msg) — cannot enforce via org rulesets

---

## Changes to apply-org-policy.sh (this session, uncommitted)

Two changes made to the script since the last commit (ca70946):

**1. Gap memo moved to static file**
  Before: script generated org-policy-gaps-{org}.md at runtime via heredoc
  After:  script prints reference to docs/org-policy-gaps.md (this file)
  Reason: runtime-generated files go stale; a versioned doc is the right home

**2. Repo naming enforcement comment corrected**
  Before: "needs GitHub Actions webhook on repo.created"
  After:  "use GHEC org repository policy — public preview"
  Reason: GHEC Repository Policies (public preview, Dec 2024) supports 'Restrict names'
          enforced at creation time; no GitHub Action needed

---

See docs/not-terraform-enforceable.md for full list and implementation notes.
