# The one resource in this layer that writes into another layer's hosted zone.
# It is in its own file so that cross-layer write is visible in the file list
# rather than buried at the bottom of alb.tf.
#
# The zone survives teardown — it lives in foundation — so a rebuild recreates
# this record pointing at a new ALB, and the hostname keeps working with no
# manual step. That property is the whole reason the zone is not in this layer.

resource "aws_route53_record" "api" {
  zone_id = local.foundation.zone_id
  name    = local.api_domain
  type    = "A"

  # An alias, not a CNAME: an ALB has no stable IP address, alias records
  # resolve for free rather than costing a lookup, and only an alias can sit at
  # a zone apex should this ever need to.
  alias {
    name    = aws_lb.this.dns_name
    zone_id = aws_lb.this.zone_id

    # A good default in staging, and load-bearing in production: during a
    # blue/green shift, health is the signal that a colour is serving, and
    # Route 53 must stop answering with an ALB whose targets are all unhealthy
    # rather than sending users at a shift that has gone wrong. Unconditional
    # because the correct answer does not differ between the two.
    evaluate_target_health = true
  }
}
