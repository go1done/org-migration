# org-policies/policies/encryption.rego
package terraform.encryption

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_s3_bucket_server_side_encryption_configuration"
    resource.change.actions[_] == "delete"
    msg := sprintf(
        "Cannot remove encryption from S3 bucket '%s'",
        [resource.name]
    )
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_ebs_volume"
    resource.change.actions[_] == "create"
    not resource.change.after.encrypted
    msg := sprintf(
        "EBS volume '%s' must be encrypted",
        [resource.name]
    )
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_db_instance"
    resource.change.actions[_] == "create"
    not resource.change.after.storage_encrypted
    msg := sprintf(
        "RDS instance '%s' must have storage encryption enabled",
        [resource.name]
    )
}
