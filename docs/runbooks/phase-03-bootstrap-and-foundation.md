# Runbook — Phase 3: bootstrap and foundation applies

**Date:** 2026-08-24
**Layers:** `infra/bootstrap`, `infra/foundation`
**Estimated time:** 20–30 minutes, most of it waiting for ACM
**Cost after completion:** ~$1/month, and it stays that way until Phase 4

This runbook creates the first AWS resources in the project. The Terraform it
applies was written and verified in Phase 3 without an AWS session; this is the
half that needs one.

**It contains the three irreducibly manual steps of the entire project.** They
are steps 4, 5 and 6, and none of them can be done by Terraform.

---

## 1. Preconditions

```bash
aws sso login --profile bootcamp-administrator-access
make verify-aws
```

Expected: account `590184028094`, region `us-east-1`, both ticked.

```bash
make tf-check
```

Expected: `all infra checks passed`. This runs `validate`, `tflint`, `checkov`
and both test suites, and needs no AWS session — so a failure here is a code
problem, not a credentials problem.

```bash
git status --porcelain
```

Expected: empty. Step 7 refuses to seed an image built from a dirty tree,
because a `-dirty` tag names something that is not any commit.

---

## 2. Apply `bootstrap`

```bash
make plan-bootstrap
```

Expected: **8 resources to add, 0 to change, 0 to destroy** — the bucket, plus
versioning, encryption, public access block, ownership controls, lifecycle
configuration and the TLS-only bucket policy.

Read the plan. In particular confirm the bucket name is
`bgd-us-east-1-tfstate-590184028094`. It is globally unique and immutable:
changing it later means creating a second bucket and migrating five state files.

```bash
make apply-bootstrap
```

### What just happened to the state

This layer's state is now a **local file**, `infra/bootstrap/terraform.tfstate`,
which is gitignored and exists only on this machine. That is deliberate — a
bucket cannot store the state describing itself — and it is not fragile,
because the layer describes exactly one resource whose name is fixed by
convention.

If it is ever lost:

```bash
terraform -chdir=infra/bootstrap import \
  aws_s3_bucket.tfstate bgd-us-east-1-tfstate-590184028094
terraform -chdir=infra/bootstrap plan
```

The plan will show the six configuration resources as additions; applying them
is idempotent against a bucket that already has those settings.

---

## 3. Apply `foundation`

```bash
make plan-foundation
```

**Stop and read two things in this plan.**

**First: the zone must be adopted, not created.** The plan should contain **no**
`aws_route53_zone.this` resource at all. If it shows one being created, the
account does not hold the zone Phase 0 found — do not apply. Investigate with
`aws route53 list-hosted-zones-by-name --dns-name carloscloudengineer.com`
before going further, because creating a second zone for a delegated domain
produces a zone whose name servers nobody points at, and the certificate
validation in this same apply will then hang for 75 minutes before failing.

**Second: the certificate names.** `api.carloscloudengineer.com` as the primary
and `staging-api.carloscloudengineer.com` as the SAN.

```bash
make apply-foundation
```

The apply **blocks on `aws_acm_certificate_validation.api`**, usually for two to
five minutes. That is the wait for ACM to see the validation CNAMEs and issue.
It is not a hang.

If it does hang past ten minutes, the DNS delegation is wrong rather than slow.
Recover without losing the apply:

```bash
# in infra/foundation/terraform.tfvars
wait_for_validation = false
```

then `make apply-foundation` to land everything else, fix the delegation at the
registrar, remove the line and apply again.

Record the outputs:

```bash
terraform -chdir=infra/foundation output
```

---

## 4. Manual step 1 of 3 — authorise the GitHub connection

Terraform created the connection in `PENDING`. A pending connection cannot be
used by any pipeline, and no amount of Terraform will change that: the
authorisation is an OAuth handshake with GitHub that requires a human.

**Console:** Developer Tools → Settings → Connections → `bgd-us-east-1-github`
→ **Update pending connection** → install or select the GitHub app for
`carreque/bluegreenDeployment` → Connect.

**Verify:**

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=infra/foundation output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' --output text
```

Expected: `AVAILABLE`. **Phase 7 cannot start until this says so.**

---

## 5. Manual step 2 of 3 — confirm the SNS subscription

AWS has sent a confirmation email to `carreque45@gmail.com`. Click the link in
it. Check the spam folder; the sender is `no-reply@sns.amazonaws.com`.

**Verify:**

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform -chdir=infra/foundation output -raw alerts_topic_arn)" \
  --query 'Subscriptions[].SubscriptionArn' --output text
```

Expected: a subscription ARN. `PendingConfirmation` means the click has not
happened.

**Nothing will ever error if this step is skipped.** Terraform reports the
subscription as created and `terraform plan` stays clean indefinitely. The
symptom appears in Phase 9, as failure alerts that are never delivered — and at
that point it looks like a bug in the alerting rather than an unclicked link.

---

## 6. Manual step 3 of 3 — activate the cost allocation tags

**This is the one with a deadline.**

**Console:** Billing and Cost Management → Cost allocation tags → User-defined
cost allocation tags → select `environment`, `projectName`, `region`, `owner` →
**Activate**.

Three facts about this step, in the order that matters:

1. It **cannot be done earlier**. A tag key only becomes activatable once AWS
   has observed it on a real resource, and this apply created the first ones.
2. It is **not retroactive**. Cost recorded before activation is permanently
   unattributed, and there is no backfill.
3. Terraform **cannot do it**. No provider resource covers tag activation.

So delay costs nothing in schedule and everything in data. Activation itself
takes up to 24 hours to appear in Cost Explorer; that lag is normal.

See [the naming and tagging convention, §6](../naming-and-tagging-convention.md#6-when-the-tags-actually-take-effect).

---

## 7. Seed the registry

The ECS services in Phases 5 and 6 will not start with an empty repository.

```bash
git status --porcelain     # must be empty
make build
make seed-ecr
```

Expected, from `seed-ecr`:

```
==> seeding 590184028094.dkr.ecr.us-east-1.amazonaws.com/bgd-us-east-1-api:0.1.0-<sha>
  local digest  sha256:…
  ✓ seeded …
  digest  sha256:…
```

The two digests are compared, not merely printed: the script fails if what ECR
stores differs from `app/dist/image-digest.txt`. That equality is the whole
reason it copies the OCI archive with skopeo rather than pushing the Docker
daemon's copy.

**Record the digest.** Phases 5 and 6 set `BGD_IMAGE_DIGEST` in the ECS task
definition's container environment to this value; without it a live task reports
`"image_digest": "unknown"` from `/version`.

Re-running the seed is safe. ECR tags are immutable, so a second push of the
same tag would normally fail — the script detects an existing image with the
same digest and reports success instead.

---

## 8. Verify the phase's exit criteria

Roadmap §3 gives Phase 3 four exit criteria. One command each.

**State backend live and locking**

```bash
aws s3api get-bucket-versioning --bucket bgd-us-east-1-tfstate-590184028094
```

Expected: `"Status": "Enabled"`. The `foundation` apply in step 3 having
succeeded through the S3 backend is itself the proof that locking works — it
acquired and released a `.tflock` object to do it.

**Certificate issued and validated**

```bash
aws acm describe-certificate \
  --certificate-arn "$(terraform -chdir=infra/foundation output -raw certificate_arn)" \
  --query 'Certificate.[Status,DomainName,SubjectAlternativeNames]'
```

Expected: `ISSUED`, `api.carloscloudengineer.com`, and the staging name.

**ECR holds the seeded image**

```bash
aws ecr describe-images --repository-name bgd-us-east-1-api \
  --query 'imageDetails[].[imageTags[0],imageDigest,imagePushedAt]' --output table
```

**SNS email subscription confirmed**

As in step 5 — an ARN, not `PendingConfirmation`.

---

## 9. Repair notes

**`allowed_account_ids` rejects the session.** The error names the account
Terraform found and the one it expected. This is almost always the wrong
profile or an expired token, not wrong configuration:
`aws sso login --profile bootcamp-administrator-access`. Do not "fix" it by
editing `var.account_id` — that guard exists to stop this project appearing in
someone else's account.

**`prevent_destroy` blocks a destroy of the state bucket.** That is what it is
for. `infra/bootstrap` is never destroyed: it holds the state of every other
layer, and Phase 10's teardown stops at `network`. Do not remove the flag to
make a destroy succeed.

**A `terraform destroy` of `foundation` is not part of any workflow.** The
certificate, the registry's images and the authorised CodeConnections link all
live here, and the last one costs another manual console step to recreate. The
teardown in Phase 10 destroys `prod` → `staging` → `network` and stops.

**The infra pipeline will later manage this layer.** From Phase 7, `foundation`
is deployed by a pipeline that lives inside it. A broken pipeline definition is
therefore repaired by a local `make apply-foundation`, not by the pipeline.
