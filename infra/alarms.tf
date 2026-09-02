# The four alarms the five-minute bake period is gated on.
#
# They are in their own file rather than in ecs.tf because they are one of the
# two things a reviewer comparing this layer to staging needs to find, and
# burying them at the bottom of a 200-line ecs.tf hides the diff that is the
# whole point of this phase.
#
# THE THRESHOLDS ARE CHOSEN, NOT MEASURED. Five target-5xx responses in a
# minute, a 2-second p95, one unhealthy host. They are stated as chosen here so
# that nobody later mistakes them for empirical. The runbook's step 10 records
# the real numbers under real traffic, and adjusting them is a one-line change.
# A threshold too tight rolls back a good deployment; too loose and the bake
# gates nothing. Both are visible from the first real deployment. Plan §D8.
#
# --- why the dimensions differ between the alarms ----------------------------
#
# deployment_configuration.alarms.alarm_names is a static list. Terraform cannot
# know which target group will be green at deploy time, so the dimension choice
# is forced rather than a matter of taste.
#
# HTTPCode_Target_5XX_Count and TargetResponseTime carry the LoadBalancer
# dimension only. They then measure what users actually experience, which is the
# rollback criterion. Scoping them per target group would also trip on the *old*
# group's errors as it drains, which is not a reason to roll back a promotion
# that already happened.
#
# UnHealthyHostCount has no LoadBalancer-only form — CloudWatch publishes it per
# target group, because "unhealthy" is a property of a target's registration in
# a group rather than of the load balancer. So it takes two alarms, one per
# colour, both listed in alarm_names. Plan §F3.
#
# Periods are 60 seconds with one or two datapoints, and that is also forced: a
# five-minute bake cannot be gated by an alarm that needs five minutes to
# evaluate.

locals {
  # The two target groups, keyed by colour, so the unhealthy-host alarms are one
  # for_each rather than two hand-written resources that can drift apart.
  #
  # Empty when enable_prod is false, which is what gates the for_each below —
  # every alarm in this file exists to gate a bake, and staging has no bake.
  target_groups = var.enable_prod ? {
    blue  = aws_lb_target_group.blue
    green = aws_lb_target_group.green[0]
  } : {}

  # Fed straight into aws_ecs_service.api's alarms.alarm_names. Composed from
  # the alarms' own alarm_name attributes rather than restated, so a rename
  # cannot leave ECS baking against an alarm that does not exist — which would
  # not fail the apply, it would just quietly gate nothing.
  # Splat rather than a direct attribute read, because the two scalar alarms are
  # count-gated: [*] yields [] when the count is zero, where .alarm_name would
  # be an error. Resolves to the empty list in staging, which is exactly what
  # aws_ecs_service.api's alarms block wants there — see ecs.tf.
  bake_alarm_names = concat(
    aws_cloudwatch_metric_alarm.five_xx[*].alarm_name,
    aws_cloudwatch_metric_alarm.p95_latency[*].alarm_name,
    [for alarm in aws_cloudwatch_metric_alarm.unhealthy : alarm.alarm_name],
  )
}

# --- what users experience ---------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "five_xx" {
  count = var.enable_prod ? 1 : 0

  alarm_name = "${local.env_prefix}-target-5xx"
  alarm_description = join(" ", [
    "Targets returned 5xx responses during the bake period.",
    "Gates the blue/green bake; notifies the alert topic (Phase 9 D12).",
    "Threshold chosen, not measured — see the runbook's step 10.",
  ])

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"

  # Target 5xx, not ELB 5xx. A 5xx the load balancer generates itself is usually
  # "no healthy targets", which the unhealthy-host alarms below already catch
  # with a dimension that says which colour. This one is the application
  # answering badly, which is the thing a bad build actually does.
  statistic = "Sum"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 5
  period              = 60
  evaluation_periods  = 1

  treat_missing_data = "notBreaching"

  # Phase 9 D12. Read from foundation's output rather than written out, so a
  # topic that is ever recreated cannot leave four alarms pointing at an ARN
  # that no longer resolves — which does not fail an apply and does not fail a
  # plan; it just stops sending mail.
  alarm_actions = [local.foundation.alerts_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "p95_latency" {
  count = var.enable_prod ? 1 : 0

  alarm_name = "${local.env_prefix}-p95-latency"
  alarm_description = join(" ", [
    "p95 target response time exceeded the threshold during the bake period.",
    "Gates the blue/green bake; notifies the alert topic (Phase 9 D12).",
    "Threshold chosen, not measured — see the runbook's step 10.",
  ])

  namespace   = "AWS/ApplicationELB"
  metric_name = "TargetResponseTime"

  # extended_statistic, not statistic = "Average". An average hides the tail the
  # design named: a build where most requests are fine and the slowest five
  # percent have doubled is exactly the regression worth rolling back, and an
  # average would pass it.
  extended_statistic = "p95"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_p95_seconds
  period              = 60

  # Two datapoints rather than one, unlike the alarms above. Latency is the
  # noisiest of the three signals and a single slow minute during a shift is
  # expected — targets are registering, connections are warming. Two consecutive
  # minutes is a regression. Still inside a five-minute bake.
  evaluation_periods = 2

  treat_missing_data = "notBreaching"

  # Phase 9 D12. Read from foundation's output rather than written out, so a
  # topic that is ever recreated cannot leave four alarms pointing at an ARN
  # that no longer resolves — which does not fail an apply and does not fail a
  # plan; it just stops sending mail.
  alarm_actions = [local.foundation.alerts_topic_arn]
}

# --- whether either colour has a sick target ---------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  for_each = local.target_groups

  alarm_name = "${local.env_prefix}-unhealthy-${each.key}"
  alarm_description = join(" ", [
    "The ${each.key} target group has an unhealthy target.",
    "One alarm per colour because CloudWatch publishes UnHealthyHostCount per",
    "target group with no LoadBalancer-only aggregate (plan F3).",
    "Gates the blue/green bake; notifies the alert topic (Phase 9 D12).",
  ])

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = each.value.arn_suffix
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"

  # One. With desired_count = 2 across two availability zones, one unhealthy
  # target is half the capacity — and during a shift both colours are running,
  # so "one is sick" is a real signal rather than a synonym for "the service is
  # down". That is the second reason production runs two tasks (plan D13).
  threshold          = 1
  period             = 60
  evaluation_periods = 1

  # Load-bearing, not cosmetic. The idle target group publishes no
  # UnHealthyHostCount at all, so the default would park this alarm permanently
  # in INSUFFICIENT_DATA — and whether ECS treats INSUFFICIENT_DATA as breaching
  # is not something to find out during a production traffic shift.
  treat_missing_data = "notBreaching"

  # Phase 9 D12. Read from foundation's output rather than written out, so a
  # topic that is ever recreated cannot leave four alarms pointing at an ARN
  # that no longer resolves — which does not fail an apply and does not fail a
  # plan; it just stops sending mail.
  alarm_actions = [local.foundation.alerts_topic_arn]
}
