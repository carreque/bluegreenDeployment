resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required, and neither is the default. Fargate reaches ECR,
  # CloudWatch Logs and DynamoDB by hostname; the gateway endpoints in
  # endpoints.tf are only consulted after DNS has resolved the service name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Every VPC is created with a default security group that allows all traffic
# between members. Nothing here uses it, but "nothing uses it" is a property of
# today's configuration rather than a control. Adopting it with no rules makes
# it inert. (checkov CKV2_AWS_12)
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-default-sg-locked"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}
