# AD Groups → GitHub Teams Design

**Date:** 2026-02-22
**Status:** Approved

## Problem

The current `teams.tf` manages GitHub Team membership via explicit GitHub usernames in `maintainers`/`members` lists. This requires manual updates as people join or leave teams.

## Decision

Use GitHub Enterprise Cloud native **Team Sync** to link each GitHub Team to an Azure AD group. Membership is automatically kept in sync by GitHub — no manual username management needed.

## Approach

**1:1 mapping** — one Azure AD group per GitHub Team, using the `github_team_sync_group_mapping` Terraform resource.

## Changes

### `teams.tf`

- Add optional `idp_group` object to the `teams` variable (`group_id`, `group_name`, optional `group_description`)
- Add `github_team_sync_group_mapping` resource — only creates for teams where `idp_group != null`
- Make `github_team_membership` resources conditional — only apply when `idp_group == null` (prevents conflict with Team Sync)

### `teams.auto.tfvars`

- Remove empty `maintainers`/`members` lists
- Add `idp_group` block per team with `CHANGEME` placeholders for `group_id` and `group_name`

## Prerequisites

- GHEC with SAML SSO already configured ✓
- Azure AD group Object IDs — retrieve from GitHub Org Settings → Authentication security → Identity provider groups
- Team Sync must be enabled at org level (enabled automatically when SAML SSO is active on GHEC)
