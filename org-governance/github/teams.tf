# org-governance/github/teams.tf
variable "teams" {
  description = "Map of team configurations"
  type = map(object({
    description = string
    privacy     = optional(string, "closed")
    maintainers = optional(list(string), [])
    members     = optional(list(string), [])
    idp_group = optional(object({
      group_id          = string
      group_name        = string
      group_description = optional(string, "")
    }))
  }))
  default = {}
}

resource "github_team" "teams" {
  for_each = var.teams

  name        = each.key
  description = each.value.description
  privacy     = each.value.privacy
}

resource "github_team_sync_group_mapping" "teams" {
  for_each  = { for k, v in var.teams : k => v if v.idp_group != null }
  team_slug = github_team.teams[each.key].slug

  group {
    group_id          = each.value.idp_group.group_id
    group_name        = each.value.idp_group.group_name
    group_description = each.value.idp_group.group_description
  }
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
      ] if team.idp_group == null
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
      ] if team.idp_group == null
    ]) : pair.key => pair
  }

  team_id  = each.value.team_id
  username = each.value.username
  role     = each.value.role
}
