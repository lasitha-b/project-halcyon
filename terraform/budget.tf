# Project Halcyon — AWS deployment path, cost guardrail.
#
# This is a paid, always-on environment unlike the one-time local KVM
# build. Alerts at 80% of the monthly threshold; the actual cost-avoidance
# mechanism is remembering to run scripts/aws-destroy.sh when a session ends
# - this alarm is a backstop for when that's forgotten.

resource "aws_budgets_budget" "halcyon_lab" {
  name         = "halcyon-lab-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project_tag)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type              = "PERCENTAGE"
    notification_type           = "ACTUAL"
    subscriber_email_addresses  = [var.budget_alert_email]
  }
}
