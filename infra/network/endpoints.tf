# Gateway endpoints are free. They work by adding a prefix-list route to each
# associated route table, so traffic to the service never reaches the NAT and
# is never billed for data processing.
#
# Only the public route tables are left out: nothing in a public subnet talks
# to S3 or DynamoDB, and the ALB nodes there need the internet gateway.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${local.name_prefix}-s3-endpoint"
  }
}

# Not named by roadmap §3 or design §3.1, and added deliberately (plan §D4).
# Every account read and every transaction write the application makes is a
# DynamoDB call; without this each one leaves through the NAT and pays
# $0.045/GB to reach a service inside the same region.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${local.name_prefix}-dynamodb-endpoint"
  }
}
