# org-governance/github/teams.tf
variable "teams" {
  description = "Map of team configurations"
  type = map(object({
    description = string
    privacy     = optional(string, "closed")
    maintainers = optional(list(string), [])
    members     = optional(list(string), [])
  }))
  default = {}
}

resource "github_team" "teams" {
  for_each = var.teams

  name        = each.key
  description = each.value.description
  privacy     = each.value.privacy
}

resource "github_team_membership" "maintainers" {
  for_each = {
    for pair in flatten([
      for team_name, team in var.teams : [
        for user in team.maintainers : {
          key      = "${team_name}-${user}"
          team_id  = github_team.teams[team_name].id
          username = user
          role     = "maintainer"
        }
      ]
    ]) : pair.key => pair
  }

  team_id  = each.value.team_id
  username = each.value.username
  role     = each.value.role
}

resource "github_team_membership" "members" {
  for_each = {
    for pair in flatten([
      for team_name, team in var.teams : [
        for user in team.members : {
          key      = "${team_name}-${user}"
          team_id  = github_team.teams[team_name].id
          username = user
          role     = "member"
        }
      ]
    ]) : pair.key => pair
  }

  team_id  = each.value.team_id
  username = each.value.username
  role     = each.value.role
}
