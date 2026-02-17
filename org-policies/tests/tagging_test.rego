# org-policies/tests/tagging_test.rego
package terraform.tagging_test

import rego.v1
import data.terraform.tagging

test_deny_missing_tags if {
    result := tagging.deny with input as {
        "resource_changes": [{
            "type": "aws_s3_bucket",
            "name": "test",
            "change": {
                "actions": ["create"],
                "after": {"tags": {}}
            }
        }]
    }
    count(result) > 0
}

test_allow_all_tags if {
    result := tagging.deny with input as {
        "resource_changes": [{
            "type": "aws_s3_bucket",
            "name": "test",
            "change": {
                "actions": ["create"],
                "after": {
                    "tags": {
                        "Environment": "prod",
                        "Owner": "platform",
                        "Project": "aft",
                        "ManagedBy": "terraform"
                    }
                }
            }
        }]
    }
    count(result) == 0
}
