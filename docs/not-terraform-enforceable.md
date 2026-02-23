# Rules Not Enforceable via Terraform

The following rules were specified in the org governance policy images but **cannot be enforced
through Terraform** (GitHub provider or otherwise). Each item notes the reason and the recommended
alternative enforcement mechanism.

| # | Rule | Reason | Source |
|---|------|--------|--------|
| 1 | `spike` branches cannot merge anywhere | GitHub rulesets have no source-branch restriction | `Github Rulesets` |
| 2 | `feature` cannot merge to `main` | Same — no source-branch restriction | `Github Rulesets` |
| 3 | Squash for `release→main`, no squash for `feature→*` | Merge method is repo-wide, not per source branch | `Github Rulesets` |
| 4 | Merges to `main` restricted to assigned team only | Rulesets control bypass actors, not allowlist of mergers | `Github Rulesets` |
| 5 | Auto-delete branches after 90/180 days | GitHub has no time-based branch deletion; needs a cron workflow | `Org settings` |
| 6 | Repository naming convention | GitHub rulesets don't govern repo names | `github_action` |
| 7 | Every repo must have a `README.md` | Rulesets can't inspect file contents | `github_action` |
| 8 | Every repo must have `dev` and `lab` branches | Branch existence can't be enforced org-wide | `github_action` |
| 9 | Unix line endings (`\n` only, CRLF rejected) | Git-level; needs `.gitattributes` per repo | `github_action` |
| 10 | Repos must have an "About" description | No enforcement mechanism at creation time | `github_action` |
| 11 | Repos must store metadata (contact, AIT, team) | GitHub Custom Properties — not enforceable via Terraform | `Team standards` |
| 12 | All teams must be IdP-linked (no manual membership) | Terraform configures it; can't prevent out-of-band UI changes | `Org settings` |
| 13 | Team members cannot create teams | `members_can_create_teams` not in Terraform provider v6 | `Org settings` |
| 14 | Non-admins cannot delete repos | `members_can_delete_repositories` not in Terraform provider | `Org settings` |
| 15 | Members cannot change repo visibility | Not exposed in Terraform provider | `Org settings` |
| 16 | Forks same-org only (no cross-org forks) | Provider only has a binary on/off for fork permission | `Org settings` |
| 17 | New repos via MyCloud intake portal | External process | `Team standards` |
| 18 | Commit messages must end with `-jmp` | Client-side git hook; can't be enforced via org rulesets | `Team standards` |
| 19 | Commit messages: imperative mood, under 100 chars | Style — can't be evaluated by regex | `Team standards` |
| 20 | AD groups created in GITHUB-CDS (external IdP) | External system — out of Terraform scope | `Org settings` |
| 21 | `CODEOWNERS` co-located with governed content | File placement convention — not a platform setting | `Team standards` |

---

## Alternatives by Item

### 1. `spike` branches must never merge into any branch
- GitHub Actions workflow on `pull_request` that fails if the source branch matches `spike/*`.
- Branch protection rule blocking `spike/*` from targeting any protected branch (manual UI or a custom GitHub App).

### 2. `feature` branches must not merge directly into `main`
- GitHub Actions status check on PRs targeting `main` that rejects `feature/*` sources.

### 3. `release` → `main` PRs must use squash commits; `feature` PRs must NOT use squash commits
- Enforce via a GitHub Actions check that validates the merge method before merge is allowed.
- Cultural/process enforcement reinforced by CODEOWNERS review.

### 4. Restrict `main` merges to the assigned merging team only
- GitHub Actions required check that inspects the PR author's team membership before allowing merge.
- Manually configure the repository's branch protection "Restrict who can push" setting (GitHub UI only).

### 5. Auto-delete branches after 90/180 days
- Scheduled GitHub Actions workflow (cron) that lists all merged branches older than the threshold and deletes them via the GitHub API.

### 6. Repository naming convention
- Validate names in the MyCloud intake portal before repo creation.
- GitHub App or org-level webhook on `repository` (created) events to alert if the name doesn't comply.

### 7. Every repository must have a `README.md`
- Extend `org-shared-workflows/repo-compliance-check.yml` to check for `README.md` presence via the GitHub API.

### 8. Every repository must have `dev` and `lab` branches
- For Terraform-managed repos: add a `github_branch` resource for `dev` and `lab` in `repos.tf`.
- For repos created via the intake portal: add branch creation to the repo-setup automation step.

### 9. Unix line endings (`\n` only, CRLF rejected)
- Add a `.gitattributes` file to every repo's default template:
  ```
  * text=auto eol=lf
  ```

### 10. Repos must have an "About" description
- Validate at intake (MyCloud portal) — require description before repo provisioning.
- GitHub Actions workflow on `repository` (created or edited) event to alert if description is blank.

### 11. Repos must store metadata (contact, AIT, team)
- Create custom property definitions via `github_organization_custom_property` (GitHub Enterprise Cloud) and validate at intake.

### 12. All teams must be IdP-linked; no local membership management
- Org policy: admins must not make manual membership changes.
- Periodic drift detection using `terraform plan` in CI to flag out-of-band changes.

### 13. Team members cannot create teams
- Set manually in GitHub org settings UI: **Settings → Member privileges → Team creation → "Only organization owners"**.

### 14. Non-admins cannot delete repos
- Set manually in GitHub org settings UI: **Settings → Member privileges → Repository deletion and transfer → disable for members**.

### 15. Members cannot change repo visibility
- GitHub enforces this implicitly when `members_can_create_public_repositories = false` and `members_can_create_internal_repositories = false` (already configured). Visibility changes by members are separately controlled in org settings UI.

### 16. Forks same-org only (no cross-org forks)
- GitHub org settings UI: **Settings → Member privileges → Forks → restrict to "Within this organization"**.

### 17. New repos via MyCloud intake portal
- Process requirement — enforce at the intake workflow level.

### 18. Commit messages must end with `-jmp`
- Client-side `commit-msg` git hook distributed via a shared hook template.

### 19. Commit messages: imperative mood, under 100 characters
- Linting via a `commit-msg` hook (e.g. `commitlint`) distributed to all developers.

### 20. AD groups created in GITHUB-CDS
- Managed externally in the IdP system; Terraform manages only the GitHub-side mapping via `github_team_sync_group_mapping`.

### 21. `CODEOWNERS` co-located with governed content
- Code review process enforcement; the `require_code_owner_review = true` ruleset ensures CODEOWNERS files are respected but does not validate their location.
