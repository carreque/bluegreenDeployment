# The one resource in this layer that writes into another layer's hosted zone.
# It is in its own file so that cross-layer write is visible in the file list
# rather than buried at the bottom of alb.tf.
#
# The zone survives teardown — it lives in foundation — so a rebuild recreates
# this record pointing at a new ALB, and the hostname keeps working with no
# manual step. That property is the whole reason the zone is not in this layer.

resource "aws_route53_record" "api" {
  zone_id = local.foundation.zone_id
  name    = local.foundation.staging_api_domain
  type    = "A"

  # An alias, not a CNAME: an ALB has no stable IP address, alias records
  # resolve for free rather than costing a lookup, and only an alias can sit at
  # a zone apex should this ever need to.
  alias {
    name    = aws_lb.this.dns_name
    zone_id = aws_lb.this.zone_id

    # Route 53 stops answering with this record if the ALB has no healthy
    # targets. With one record and one ALB that changes nothing today, but it
    # is the correct default and Phase 6 inherits the habit.
    evaluate_target_health = true
  }
}
