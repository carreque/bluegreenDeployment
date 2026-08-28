# Public and private are separate resources rather than one for_each over a map
# of tiers, because they differ in more than a tag: map_public_ip_on_launch,
# their route tables and their consumers are all different. Merging them would
# put a conditional in every attribute.

resource "aws_subnet" "public" {
  # checkov:skip=CKV_AWS_130:a public subnet that does not assign public addresses cannot host a NAT gateway or an internet-facing ALB's nodes. The private subnets set this to false explicitly and pass the same check.
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # The NAT Gateway needs one, and an internet-facing ALB's nodes are placed
  # here. Nothing else is launched into these subnets.
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${local.az_suffixes[count.index]}"
    tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Explicit rather than omitted. The attribute defaults to false, but a
  # Fargate task with a public IP would bypass the NAT entirely and quietly
  # invalidate every assertion this layer makes about egress.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${local.az_suffixes[count.index]}"
    tier = "private"
  }
}
