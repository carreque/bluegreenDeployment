output "vpc_id" {
  description = "The VPC both environment layers place their resources in."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Address space of the VPC. Environment layers scope in-VPC rules against it rather than restating the range."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Subnets for the internet-facing ALBs, ordered by availability zone."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subnets for the Fargate tasks, ordered by availability zone and index-aligned with public_subnet_ids."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "The zones this layer spans, in the order the subnet lists use."
  value       = local.azs
}

output "nat_gateway_public_ip" {
  description = "The address every private-subnet egress appears to come from. scripts/verify-network.sh asserts against it."
  value       = aws_eip.nat.public_ip
}

output "alb_security_group_ids" {
  description = "Per-environment ALB security groups, keyed staging and prod."
  value       = { for env, sg in aws_security_group.alb : env => sg.id }
}

output "task_security_group_ids" {
  description = "Per-environment Fargate task security groups, keyed staging and prod."
  value       = { for env, sg in aws_security_group.task : env => sg.id }
}

output "container_port" {
  description = "Port the security group rules open, so the environment layers' task definitions cannot disagree with them."
  value       = var.container_port
}
