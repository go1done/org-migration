# org-policies/policies/tagging.rego
package terraform.tagging

import rego.v1

required_tags := {"Environment", "Owner", "Project", "ManagedBy"}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.change.actions[_] == "create"
    tags := object.get(resource.change.after, "tags", {})
    missing := required_tags - {key | tags[key]}
    count(missing) > 0
    msg := sprintf(
        "%s '%s' is missing required tags: %v",
        [resource.type, resource.name, missing]
    )
}
