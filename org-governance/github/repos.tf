# org-governance/github/repos.tf
variable "repositories" {
  description = "Map of repository configurations"
  type = map(object({
    description            = string
    visibility             = optional(string, "private")
    has_issues             = optional(bool, true)
    has_wiki               = optional(bool, false)
    has_projects           = optional(bool, false)
    delete_branch_on_merge = optional(bool, true)
    auto_init              = optional(bool, false)
    archive_on_destroy     = optional(bool, true)
    vulnerability_alerts   = optional(bool, true)
    topics                 = optional(list(string), [])
    team_access = optional(map(string), {})
    # team_name => permission (pull, triage, push, maintain, admin)
  }))
  default = {}
}

resource "github_repository" "repos" {
  for_each = var.repositories

  name                   = each.key
  description            = each.value.description
  visibility             = each.value.visibility
  has_issues             = each.value.has_issues
  has_wiki               = each.value.has_wiki
  has_projects           = each.value.has_projects
  delete_branch_on_merge = each.value.delete_branch_on_merge
  auto_init              = each.value.auto_init
  archive_on_destroy     = each.value.archive_on_destroy
  vulnerability_alerts   = each.value.vulnerability_alerts
  topics                 = each.value.topics

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
}

resource "github_team_repository" "access" {
  for_each = {
    for pair in flatten([
      for repo_name, repo in var.repositories : [
        for team_name, permission in repo.team_access : {
          key        = "${repo_name}-${team_name}"
          repository = repo_name
          team_id    = github_team.teams[team_name].id
          permission = permission
        }
      ]
    ]) : pair.key => pair
  }

  repository = each.value.repository
  team_id    = each.value.team_id
  permission = each.value.permission

  depends_on = [github_repository.repos]
}
