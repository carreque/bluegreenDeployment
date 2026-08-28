resource "aws_eip" "nat" {
  domain = "vpc"

  # The gateway must exist before the address is attached to it, and Terraform
  # cannot infer the ordering from the arguments alone.
  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

# One NAT Gateway, in the first AZ, shared by both environments. This is the
# design's recorded cost trade (§3.1): a second one would double the largest
# line item on the bill to buy AZ-failure resilience that a portfolio project
# does not need. The consequence is real and worth naming — if this AZ fails,
# tasks in the other AZ lose egress.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${local.name_prefix}-nat"
  }
}

# One public route table for both public subnets: they share a destination.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ, even though both currently point at the same
# NAT. They cost nothing, and they are what makes "give AZ b its own NAT" an
# edit to one route rather than a restructuring of the layer.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-private-rt-${local.az_suffixes[count.index]}"
  }
}

resource "aws_route" "private_nat" {
  count = var.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
