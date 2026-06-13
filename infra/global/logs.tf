# Account-wide CloudWatch Logs data protection: any string matching the token
# format is masked in every log group (Lambda, EC2/docker, API GW access logs).
# Unmasking requires the logs:Unmask permission, which no role here is granted.
resource "aws_cloudwatch_log_account_policy" "redact_token" {
  policy_name = "${var.project}-redact-secret-token"
  policy_type = "DATA_PROTECTION_POLICY"
  scope       = "ALL"

  policy_document = jsonencode({
    Name    = "${var.project}-redact-secret-token"
    Version = "2021-06-01"

    Configuration = {
      CustomDataIdentifier = [
        {
          Name  = "DockyardToken"
          Regex = local.token_regex
        }
      ]
    }

    Statement = [
      {
        Sid            = "audit"
        DataIdentifier = ["DockyardToken"]
        Operation = {
          Audit = {
            FindingsDestination = {}
          }
        }
      },
      {
        Sid            = "redact"
        DataIdentifier = ["DockyardToken"]
        Operation = {
          Deidentify = {
            MaskConfig = {}
          }
        }
      }
    ]
  })
}
