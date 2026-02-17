# org-policies/policies/networking.rego
package terraform.networking

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_security_group_rule"
    resource.change.actions[_] == "create"
    resource.change.after.type == "ingress"
    resource.change.after.cidr_blocks[_] == "0.0.0.0/0"
    resource.change.after.from_port != 443
    msg := sprintf(
        "Security group rule '%s' allows ingress from 0.0.0.0/0 on port %d (only 443 allowed)",
        [resource.name, resource.change.after.from_port]
    )
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_security_group"
    resource.change.actions[_] == "create"
    ingress := resource.change.after.ingress[_]
    ingress.cidr_blocks[_] == "0.0.0.0/0"
    ingress.from_port == 0
    ingress.to_port == 0
    msg := sprintf(
        "Security group '%s' allows all traffic from 0.0.0.0/0",
        [resource.name]
    )
}
