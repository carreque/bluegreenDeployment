# infra

Terraform, split into **five layers**. Each layer is a root module with its own
state file; `modules/` holds reusable code that is never applied directly.

| Layer | Lifetime | Idle cost | Phase |
|---|---|---|---|
| `bootstrap/` | never destroyed | $0 | 3 |
| `foundation/` | persistent | ~$1/mo | 3 |
| `network/` | ephemeral | ~$34/mo (unverified — pending [runbook §8](../docs/runbooks/phase-04-network.md)'s pricing-API check) | 4 |
| `environments/staging/` | ephemeral | ~$25/mo | 5 |
| `environments/prod/` | ephemeral | ~$40/mo | 6 |

The split exists because of the destroy-when-idle policy. The NAT Gateway is the
largest idle cost and lives in `network`; the hosted zone, ACM certificate, ECR
images and the CodeConnections link — which needs a manual console click — live in
`foundation`. Separate state files are what let `terraform destroy` on `network`
run without being able to reach any of that.

**Teardown** destroys `prod` → `staging` → `network`. **Rebuild** applies the
reverse. Layers read each other through `terraform_remote_state`.
