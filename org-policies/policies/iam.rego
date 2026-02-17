# org-policies/policies/iam.rego
package terraform.iam

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_iam_policy"
    resource.change.actions[_] == "create"
    policy_doc := json.unmarshal(resource.change.after.policy)
    statement := policy_doc.Statement[_]
    statement.Effect == "Allow"
    action := statement.Action[_]
    action == "*"
    msg := sprintf(
        "IAM policy '%s' must not use wildcard (*) actions",
        [resource.name]
    )
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_iam_role_policy"
    resource.change.actions[_] == "create"
    policy_doc := json.unmarshal(resource.change.after.policy)
    statement := policy_doc.Statement[_]
    statement.Effect == "Allow"
    statement.Resource == "*"
    action := statement.Action[_]
    action == "*"
    msg := sprintf(
        "IAM inline policy on role '%s' must not use wildcard (*) actions with wildcard resources",
        [resource.name]
    )
}
