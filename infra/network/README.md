# infra/network — Phase 4

Ephemeral and the most expensive thing to leave running: roadmap §3 estimates
~$34/month, almost all of it the NAT Gateway. **That figure is unverified as
plan-time arithmetic; the [runbook](../../docs/runbooks/phase-04-network.md)'s
step 8 confirms it against the pricing API before it can be trusted.** First
layer destroyed at teardown, first rebuilt.

A flat root module, matching `bootstrap` and `foundation` in shape. It reads
**no `terraform_remote_state`** — it consumes no resource from `foundation`,
only the naming and tagging convention's four variables, which it rebuilds
itself rather than importing. This keeps `make tf-check` fully offline (no
remote-state data source to mock in every test file) and keeps `terraform
destroy` on this layer working even if `foundation`'s state is unreadable —
which matters because destroying `network` is routine, not exceptional.
Phases 5 and 6, by contrast, do take remote state on `foundation`, because
they need real ARNs (certificate, zone, registry) that cannot be rebuilt from
a variable.

## What this layer builds

- **One VPC**, `bgd-us-east-1-vpc`, across two availability zones, with the
  account's default security group adopted and locked to zero rules.
- **The address plan:**

  | Tier | AZ a | AZ b |
  |---|---|---|
  | Public | `10.0.0.0/24` | `10.0.1.0/24` |
  | Private | `10.0.16.0/20` | `10.0.32.0/20` |

  Public subnets are `/24`s — an ALB needs eight usable addresses and nothing
  else lives there. Private subnets are `/20`s, because every Fargate task
  takes an ENI and an address, and blue/green runs two task sets at once. The
  private ranges start at index 1 so they cannot overlap the public `/24`s,
  which sit inside the first `/20` (`10.0.0.0`–`10.0.15.255`).

- **One internet gateway, one shared NAT Gateway, and per-AZ private route
  tables.** The NAT sits in the first AZ's public subnet and is the design's
  recorded cost trade (design §3.1): a second one would double the layer's
  largest line item to buy AZ-failure resilience a portfolio project does not
  need. The consequence is real — if that AZ fails, the other AZ's tasks lose
  all egress — and it is accepted rather than hidden. Because each AZ keeps
  its own private route table even though both point at the same NAT today,
  giving the second AZ its own NAT later is a one-line route change, not a
  restructuring of the layer.

- **Both free gateway endpoints — S3 and DynamoDB.** Design §3.1 named only
  S3, which keeps ECR layer pulls off the NAT's data-processing meter (ECR
  stores image layers in S3). The DynamoDB endpoint was added deliberately in
  Phase 4: DynamoDB is the application's entire data path, and without it
  every account read and every transaction write would leave through the NAT
  at $0.045/GB for traffic that never needed to leave AWS. Both are attached
  to every private route table and to none of the public ones — nothing in a
  public subnet talks to S3 or DynamoDB, and the ALB nodes there need the
  internet gateway, not a service endpoint.

- **VPC flow logs**, `ALL` traffic (accept and reject), to
  `/bgd/us-east-1/shared/vpc-flow` at 7-day retention. Short retention is
  deliberate: they are a debugging aid for an ephemeral layer that is
  destroyed when idle, and retention is the entirety of what they cost. They
  are the tool that answers "why can this task not reach that endpoint" —
  Phase 5 and 6's single most likely failure mode — so the evidence exists
  from the first apply rather than being switched on after something breaks.

- **Four security groups, one ALB/task pair per environment**, not one shared
  pair. `bgd-us-east-1-staging-alb-sg` / `-task-sg` and the `prod` equivalents
  are fully isolated from each other: a staging task cannot reach a
  production task, and vice versa. Production's ALB security group opens an
  additional `:8443` — the blue/green test listener Phase 6 shifts traffic to
  before any user sees the new colour — which staging's does not need. This
  is deliberate asymmetry, not an omission: it means Phase 6 never has to
  reopen this layer to add a port. Task egress is `:443` plus DNS (`:53`
  UDP and TCP to the VPC resolver), not "all traffic" — everything a Fargate
  task needs is HTTPS: the ECR auth token, image layers via the S3 endpoint,
  CloudWatch Logs, DynamoDB via its endpoint, and any third-party API.

  All four security groups set `create_before_destroy`, because they are
  created here but attached by the ALB and ECS service in Phases 5 and 6,
  which live in different state files — a rename must not break a live
  reference from another layer.

## What this layer does not build

Interface VPC endpoints (design §3.1 priced them and chose NAT), a second NAT
Gateway for AZ redundancy, and anything under `app/`, `bootstrap/` or
`foundation/`.

## Outputs

Consumed by both environment layers: VPC id and CIDR, public and private
subnet ids (index-aligned by AZ), the NAT Gateway's public IP (what
`scripts/verify-network.sh` asserts private-subnet egress against), and the
per-environment ALB and task security group id maps.
