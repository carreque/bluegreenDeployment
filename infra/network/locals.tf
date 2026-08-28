data "aws_availability_zones" "available" {
  state = "available"

  # Opt-in zones (Local Zones, Wavelength) are not enabled on this account and
  # do not support Fargate. Without this filter the first two names returned
  # could be zones nothing can be launched into.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name_prefix = "${var.project_name}-${var.region}"

  common_tags = {
    environment = "shared"
    projectName = var.project_name
    region      = var.region
    owner       = var.owner
  }

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # "us-east-1a" -> "1a", the <az> segment convention §3 asks for in
  # bgd-us-east-1-private-1a. Splitting on "-" is clearer than a substring
  # offset, but it assumes a two-segment region name ("us-east-1"): a
  # three-segment region like "us-gov-west-1" yields "west" here, not "1a".
  # There is no region with that shape on this account today, so this is
  # believed safe rather than proven safe against every AWS partition.
  az_suffixes = [for az in local.azs : split("-", az)[2]]

  # Public subnets are /24s — an ALB needs eight usable addresses per subnet and
  # nothing else lives there. Private subnets are /20s, because every Fargate
  # task takes an ENI and an address, and blue/green runs two task sets at once.
  #
  # Carved so they cannot overlap: the /24s at newbits 8 land inside the first
  # /20 (10.0.0.0 - 10.0.15.255), and the private /20s start at index 1
  # (10.0.16.0/20) and count up from there.
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 1)]
}
