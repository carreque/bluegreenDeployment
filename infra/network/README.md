# infra/network — Phase 4

Ephemeral and the most expensive thing to leave running: roughly $33/month, almost
all of it the NAT Gateway. First layer destroyed at teardown, first rebuilt.

- VPC across two availability zones
- Public subnets for the ALBs, private subnets for the Fargate tasks
- Internet gateway, one shared NAT Gateway, route tables
- S3 gateway endpoint — free, and it keeps ECR layer pulls off the NAT's
  data-processing meter, since ECR stores image layers in S3
- Security groups: ALB-to-task and task-to-egress, least privilege

One NAT rather than interface endpoints is a deliberate cost decision. At the two
AZs this design needs, `ecr.api` + `ecr.dkr` + `logs` bill per endpoint per AZ and
come to roughly $44/month — more than NAT, while also leaving the service unable to
reach any third-party API. The reasoning is recorded in design §3.1.

Outputs are consumed by both environment layers through remote state.
