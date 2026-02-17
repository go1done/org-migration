# org-policies/policies/naming.rego
package terraform.naming

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.change.actions[_] == "create"
    tags := object.get(resource.change.after, "tags", {})
    name := object.get(tags, "Name", "")
    name != ""
    not regex.match(`^[a-z][a-z0-9-]+$`, name)
    msg := sprintf(
        "%s '%s' Name tag must be lowercase alphanumeric with hyphens (got '%s')",
        [resource.type, resource.name, name]
    )
}
