# Runbook — Phase 6: production apply and the blue/green demonstration

**Date:** 2026-08-29
**Layer:** `infra/ (enable_prod = true)`
**Estimated time:** 90–120 minutes end to end. The first apply is 10–15 minutes;
each blue/green deployment after it is 8–12, most of which is the five-minute
bake you are not allowed to skip
**Cost while it exists:** roadmap §3 estimates ~$40/month — the ALB is most of
it, two 0.25 vCPU ARM64 Fargate tasks are most of the rest, and the on-demand
tables and three rarely-invoked Lambdas cost close to nothing

This is the runbook the whole project builds toward. The Terraform and the
handler were written and verified in Phase 6 with no AWS session — 35 Terraform
test runs and 17 handler tests, all green — and **none of the phase's three exit
criteria is met by that branch.** All three need a running service. They are
met here, at steps 12, 13 and 14.

> **Read step 13 before you start step 12.** The window in which `:443` and
> `:8443` serve different SHAs is a few minutes wide and it does not come back
> without another deployment. Have those commands in a second terminal, ready
> to run, before you bump the image tag.

**Terraform initiates the deployment; the CLI observes it.** The roadmap says
blue/green is "exercised here by hand via the AWS CLI", and read literally that
would mean `aws ecs update-service --task-definition`. Do not do that. Terraform
owns the task definition and the service shape, and a CLI update registers drift
that the next `terraform apply` reverts — mid-deployment. What you change by
hand is `image_tag`; what you do by hand with the CLI is watch, and abort.

---

## 1. Preconditions

Four, and the fourth is new to this layer.

**`foundation` is applied and its certificate is `ISSUED`.** Both TLS listeners
reference it, so a certificate still in `PENDING_VALIDATION` fails the apply
twice over.

```bash
aws acm describe-certificate \
  --certificate-arn "$(terraform -chdir=infra/foundation output -raw certificate_arn)" \
  --query 'Certificate.Status' --output text
# ISSUED
```

**`network` is applied.** This layer reads six outputs from it and creates
nothing of its own in the VPC.

```bash
terraform -chdir=infra/network output -raw vpc_id
```

**An image tag exists in ECR.**

```bash
aws ecr describe-images --repository-name bgd-us-east-1-api \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[:5].imageTags[0]' --output table
```

**`staging` is green.** Not a hard dependency — `prod` does not read staging's
state — but a production blue/green deployment is a bad place to discover a bug
the rolling environment would have shown you in ninety seconds.

```bash
make smoke-staging
```

---

## 2. AWS session

```bash
aws sso login --profile bootcamp-administrator-access
make verify-aws
```

---

## 3. Confirm the managed policy exists — **before the apply**

`bgd-us-east-1-prod-bluegreen-role` attaches an AWS-managed policy by name
(plan §D5). Getting the name wrong fails the apply immediately with "policy does
not exist", before anything is created — which is benign **only if you catch it
early**, because it happens partway through a ten-minute apply otherwise.

```bash
aws iam get-policy \
  --policy-arn arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers \
  --query 'Policy.{Name:PolicyName,Attachable:IsAttachable}' --output table
```

**If this returns `NoSuchEntity`**, the fallback is in the plan's §6: replace
`aws_iam_role_policy_attachment.bluegreen` in `iam.tf` with an inline policy
granting `elasticloadbalancing:Describe*`, `ModifyRule`, `ModifyListener`,
`RegisterTargets` and `DeregisterTargets` on this ALB's listeners, rules and
both target groups — and **record it as a deviation in the local verification
record**, because D5's whole argument is that a hand-rolled list here is a
guess, and a guess that is slightly too narrow fails halfway through a
production traffic shift rather than at apply.

---

## 4. Set `image_tag`

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
cat app/dist/image-ref.txt        # or a tag from step 1
$EDITOR infra/terraform.tfvars
```

---

## 5. Re-run the offline gate against the real toolchain

Everything below this line costs money. Everything above it does not.

```bash
make tf-check
make test-lambdas
```

Expected: five layers validate, tflint and checkov clean, **152** Terraform test
runs pass (bootstrap 5, foundation 77, network 17, staging 17, prod 36), and
**68** handler tests with `lifecycle_hook/handler.py` at 100% coverage.

Counts measured 2026-09-01, not remembered. `make tf-test` needs a valid session
for every layer except `bootstrap` — the other four read remote state, and an
expired token fails them with `ExpiredToken` rather than anything about the
tests.

---

## 6. Plan

```bash
make plan-prod
```

**What to look for**, in the counts rather than line by line:

| Expect | Count |
|---|---|
| IAM roles | **5** — `task-exec`, `task`, `bluegreen`, `hook-invoke`, and three `*-exec-role` from the module (7 role resources in total; five *kinds*) |
| Lambda functions | **3** |
| CloudWatch alarms | **4** |
| Listeners | **3** — `:80`, `:443`, `:8443` |
| Listener **rules** | **2** |
| Target groups | **2** |
| DynamoDB tables | **2** |
| ECS services | **1**, with `strategy = "BLUE_GREEN"` |

Check `bake_time_in_minutes` reads `"5"` **in quotes**. It is typed string in
the provider schema, and the number form fails `validate` — if you are reading a
plan, it already passed, but this is the field worth eyeballing.

---

## 7. Apply

```bash
make apply-prod
```

**Expect this to take ten to fifteen minutes and not to return early.**
`wait_for_steady_state = true` (plan §D11) means Terraform blocks until the ECS
service actually reaches steady state. That is the point: without it, apply
returns the moment ECS *accepts* the deployment, and a rolled-back deployment
would leave you with a green plan over a red service.

**What a first apply looks like.** There is no previous revision to shift from,
so ECS does not run a full blue/green sequence: it provisions the initial task
set into the blue target group and stabilises. You may see the `PRE_SCALE_UP`
hook fire; you will not see a test traffic shift, because there is nothing to
shift away from. The blue/green machinery is exercised properly at step 12.

If it hangs past twenty minutes, go to step 16's `wait_for_steady_state` row.

---

## 8. Verify the exit-criteria baseline

```bash
make smoke-prod
```

Then by hand, both listeners:

```bash
API="$(terraform -chdir=infra/ (enable_prod = true) output -raw api_url)"
TEST="$(terraform -chdir=infra/ (enable_prod = true) output -raw test_url)"

curl -sS "$API/health" | jq .
curl -sS "$API/ready"  | jq .        # exercises DynamoDB — must be 200, not 503
curl -sS "$API/version" | jq .

curl -sS "$TEST/version" | jq .
```

**Only one colour exists right now, so `:8443` returns the same image as
`:443`.** That is correct and it is the baseline: at step 13 these two answers
diverge, and the divergence is the evidence.

---

## 9. Read the hook logs and record the real contract — **F2 is now retired**

The single largest unverified assumption in the phase. The payload ECS expects
back from a lifecycle hook is not in the provider schema and could not be
confirmed offline, so the handler was built to be correct under either plausible
contract (plan §D3): it **returns** `{"hookStatus": "SUCCEEDED"}` on success and
**raises** on failure.

```bash
for f in $(terraform -chdir=infra/ (enable_prod = true) output -json hook_function_names | jq -r '.[]'); do
  echo "=== $f ==="
  aws logs tail "/aws/lambda/$f" --since 30m --format short
done
```

**Record three things** in `docs/phases/phase6/2026-08-28-local-verification.md`:

1. **The event shape.** The handler logs it raw at INFO precisely so this step
   can read it. It was deliberately not parsed, because a handler that raised on
   an unexpected shape would fail every deployment.
2. **What ECS did with the return value.** Did the stage pass? Did anything in
   the ECS deployment record reference `hookStatus`?
3. **Whether the contract is narrower than D3 assumed.** If ECS turns out to
   *require* a specific field, add it — the handler is already correct in the
   direction that matters, so this is an addition, never a rewrite into a
   symmetric return.

> **Do not "tidy" the handler into returning `{"hookStatus": "FAILED"}` on
> failure**, whatever this step reveals. If ECS treats any successful invocation
> as a pass, a returned FAILED promotes a bad build to production — which is the
> failure the entire phase exists to prevent.

---

## 10. Record the real alarm behaviour

```bash
aws cloudwatch describe-alarms \
  --alarm-names $(terraform -chdir=infra/ (enable_prod = true) output -json bake_alarm_names | jq -r '.[]') \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}' --output table
```

Two things to confirm, both of which retire a finding:

**All four leave `INSUFFICIENT_DATA` once traffic exists** (generate some with
step 8's curls, then wait two minutes). This is what checks plan §F3 — the
belief that `UnHealthyHostCount` is published per target group with no
LoadBalancer-only aggregate. **If one of the two colour alarms stays in
`INSUFFICIENT_DATA` forever even under traffic, F3 is right and it is the idle
group's alarm, which is exactly why `treat_missing_data = "notBreaching"` is
set.** If a LoadBalancer-only aggregate turns out to exist, say so and collapse
the two into one.

**Record the observed numbers**, so D8's chosen thresholds can be replaced with
measured ones:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value="$(aws elbv2 describe-load-balancers \
      --names bgd-us-east-1-prod-alb --query 'LoadBalancers[0].LoadBalancerArn' \
      --output text | sed 's|.*loadbalancer/||')" \
  --start-time "$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --extended-statistics p95 --output table
```

The thresholds — 5 target-5xx in a minute, a 2-second p95, one unhealthy host —
are **chosen, not measured**, and `alarms.tf` says so. Too tight rolls back a
good deployment; too loose and the bake gates nothing. Adjusting is a one-line
change to `var.alarm_p95_seconds` or the literals in `alarms.tf`.

---

## 11. Build a second image — **before step 12, not during it**

Exit criterion 2 is "`/version` returns different SHAs on `:443` and `:8443`".
`git_sha` is baked into the image at build time, so producing two different
values requires **two images from two different commits** (plan §F5). One
already exists; this makes the second.

```bash
# A trivial, honest change — a comment or a version bump, not a behaviour change.
$EDITOR app/VERSION
git commit -am "chore(app): second build for the Phase 6 blue/green demonstration"

make build
make seed-ecr
cat app/dist/image-ref.txt        # the new tag — you need it in step 12
```

Phase 2's build is reproducible from the commit, so a new commit reliably
produces a new digest and a new SHA.

---

## 12. Exit criterion 1 — a blue/green deployment completes

**Two terminals. Read step 13 first.**

Terminal A — initiate:

```bash
$EDITOR infra/terraform.tfvars   # image_tag = the new tag
make apply-prod
```

Terminal B — observe (D10: Terraform initiates, the CLI observes):

```bash
CLUSTER="$(terraform -chdir=infra/ (enable_prod = true) output -raw cluster_name)"
SERVICE="$(terraform -chdir=infra/ (enable_prod = true) output -raw service_name)"

DEPLOYMENT=$(aws ecs list-service-deployments \
  --cluster "$CLUSTER" --service "$SERVICE" \
  --query 'serviceDeployments[0].serviceDeploymentArn' --output text)

watch -n 10 "aws ecs describe-service-deployments \
  --service-deployment-arns $DEPLOYMENT \
  --query 'serviceDeployments[0].{Status:status,Stage:lifecycleStage,Started:startedAt}' \
  --output table"
```

**The stages you should see, in order:** `PRE_SCALE_UP` → `SCALE_UP` →
`TEST_TRAFFIC_SHIFT` → `POST_TEST_TRAFFIC_SHIFT` → `PRODUCTION_TRAFFIC_SHIFT` →
`POST_PRODUCTION_TRAFFIC_SHIFT` → `BAKE_TIME` → `CLEAN_UP`.

**Criterion 1 is met when the deployment reaches `SUCCESSFUL` and `make
apply-prod` returns 0** — the two together, because either alone can be
misleading: a rolled-back deployment finishes, and an apply that returned
without `wait_for_steady_state` would prove nothing.

To abort a deployment by hand:

```bash
aws ecs stop-service-deployment --service-deployment-arn "$DEPLOYMENT"
```

---

## 13. Exit criterion 2 — different SHAs on `:443` and `:8443`

> **Fixed and verified 2026-09-01.** *(Superseding the 2026-08-31 note that said
> this step could not pass.)* The captured run is
> [`docs/evidence/phase-06-exit-criterion-2.txt`](../evidence/phase-06-exit-criterion-2.txt)
> — a rebuild from a destroyed account plus two deployments of different builds,
> with the criterion appearing twice and the colours alternating
> (create → green, deploy-1 → blue, deploy-2 → green).
>
> **The check to run before spending a deployment**, which is free: after the
> create, `terraform plan` against the live layer. ECS will have moved the
> production rule off the colour the config names, and the plan must still say
> `No changes`. Before the fix that divergence produced `Plan: 0 to add, 2 to
> change` — the two rule reverts that were the whole defect. If you see them,
> stop; `ignore_changes` has been lost from `alb.tf`.
>
> **Expect the create to land in green and do not read that as a failure.** The
> rules are born `production → blue` with blue empty, so ECS deploys the first
> revision into the other group. Alternation starts at the second deployment.
>
> Between the layer's creation and 2026-09-01 every revision registered into the
> same target group — `blue` never held a target across seven registrations —
> so both listeners resolved to one mixed pool and there was no window to catch.
> The cause was that Terraform reverted the two `aws_lb_listener_rule` actions at
> the start of every apply, telling ECS that blue was live when green was; ECS
> reads that rule to decide where to deploy. Both rules now carry
> `ignore_changes = [action]`.
>
> The mechanism was demonstrated by hand: with the rules left in ECS's own state
> and no apply in front of it, the incoming revision registered into blue, the
> production rule stayed on green and the test rule moved to blue. What that
> could **not** show is this step's criterion, because
> `--force-new-deployment` redeploys the same image and both ports necessarily
> reported the same digest. **This step is the outstanding verification** — read
> [blue/green does not
> isolate](../phases/phase6/2026-08-31-blue-green-does-not-isolate.md) §7 before
> running it, and record the result there.
>
> Two practical notes before you start, both of which cost time on 2026-08-31:
>
> - **Pin the hostname.** A rebuild creates a new ALB and the local resolver can
>   keep serving the destroyed one, which reads exactly like an unstable
>   rollout:
>
>   ```bash
>   ALBDNS=$(aws elbv2 describe-load-balancers --names bgd-us-east-1-prod-alb \
>     --query 'LoadBalancers[0].DNSName' --output text)
>   IP=$(dig +short "$ALBDNS" | grep -E '^[0-9.]+$' | head -1)
>   curl -sk --resolve "api.carloscloudengineer.com:8443:$IP" \
>     https://api.carloscloudengineer.com:8443/version
>   ```
>
> - **Compare the full tag, not `git_sha`.** A "Release change" rebuilds the same
>   commit, so both colours report the same SHA. The patch digit is the CodeBuild
>   build number: `0.1.5-25153bc` against `0.1.6-25153bc`. The loop below prints
>   `git_sha`; add `.version` to it, or step 11's second image must come from a
>   different commit.

**This is the direct proof of which colour serves whom, and the window is a few
minutes wide.** Have this loop running in a third terminal *before* you start
step 12:

```bash
API="$(terraform -chdir=infra/ (enable_prod = true) output -raw api_url)"
TEST="$(terraform -chdir=infra/ (enable_prod = true) output -raw test_url)"

while true; do
  printf '%s  443=%s  8443=%s\n' \
    "$(date -u +%H:%M:%S)" \
    "$(curl -sS --max-time 5 "$API/version"  | jq -r '.git_sha' 2>/dev/null)" \
    "$(curl -sS --max-time 5 "$TEST/version" | jq -r '.git_sha' 2>/dev/null)"
  sleep 5
done | tee docs/evidence/phase-06-exit-criterion-2.txt
```

**What the output shows, and what each part proves:**

| Phase of the deployment | `443` | `8443` | What it proves |
|---|---|---|---|
| Before | old SHA | old SHA | Baseline. One colour, both doors |
| After `TEST_TRAFFIC_SHIFT` | **old SHA** | **new SHA** | **The criterion.** Green is live and reachable, and not one user request has touched it |
| After `PRODUCTION_TRAFFIC_SHIFT` | new SHA | new SHA | The promotion landed |

The middle row is the evidence. Keep the file — Phase 11 references it.

The `:443` column staying on the old SHA through the whole test-shift window is
the half people forget to check, and it is the half that proves the canary was
genuinely dark.

---

## 14. Exit criterion 3 — a deliberately failing hook aborts with zero traffic shifted

The hook that fails is the post-test one, and **the check it runs is real** —
only the expectation is deliberately wrong. There is no failure toggle in the
committed infrastructure; Terraform never sets `BGD_EXPECT_DIGEST` (plan §D12),
which is what keeps this from being the "simulated failure toggle" Phase 11's
evidence standard forbids.

```bash
POST_TEST="$(terraform -chdir=infra/ (enable_prod = true) output -json hook_function_names \
             | jq -r '.[] | select(endswith("post-test-hook"))')"

aws lambda update-function-configuration \
  --function-name "$POST_TEST" \
  --environment "Variables={BGD_STAGE=POST_TEST_TRAFFIC_SHIFT,BGD_PROBE_URL=$TEST,BGD_EXPECT_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000}"

aws lambda wait function-updated-v2 --function-name "$POST_TEST"
```

> `update-function-configuration` **replaces** the whole environment map. Both
> existing variables are restated above; omit them and the hook fails for the
> wrong reason — a missing `BGD_PROBE_URL` — which would still abort the
> deployment but would prove nothing about the digest check.

> **Do NOT trigger this deployment with Terraform.** *(Corrected 2026-09-01,
> after the original instruction was tried and could not work.)*
>
> The `lambda` module manages the **whole** `environment` map, so a variable set
> by hand is drift, and the plan says so:
>
> ```
> # module.post_test_hook.aws_lambda_function.this will be updated in-place
>   - "BGD_EXPECT_DIGEST" = "sha256:0000…" -> null
> ```
>
> `aws_ecs_service.api` references `module.post_test_hook.function_arn`, so
> Terraform updates the **Lambda first and the service second** — stripping the
> expectation before the hook it is meant to fail ever runs. `make apply-prod`
> here produces a deployment that simply succeeds, and proves nothing.
>
> Plan §D12 is still true: Terraform never *sets* this variable, which is what
> keeps it out of the committed infrastructure. What does not follow — and what
> this runbook previously claimed — is that Terraform cannot *see* it.

Trigger the deployment without Terraform instead. The task definition does not
change, so this registers no drift and none of the reasoning about
`update-service --task-definition` applies:

```bash
aws ecs update-service \
  --cluster bgd-us-east-1-prod-cluster \
  --service bgd-us-east-1-prod-api \
  --force-new-deployment
```

**The trade, stated:** the incoming and outgoing revisions are the same image, so
"`:443` kept serving the old digest" is trivially true and is *not* the evidence.
The load-bearing evidence is that the **production listener rule never leaves the
outgoing colour** and the deployment ends `ROLLBACK_SUCCESSFUL` at
`POST_TEST_TRAFFIC_SHIFT`. Check 3 below is written accordingly.

**What to confirm, and confirm all three:**

```bash
# 1. The deployment was aborted at the post-test stage, not later.
aws ecs describe-service-deployments --service-deployment-arns "$DEPLOYMENT" \
  --query 'serviceDeployments[0].{Status:status,Stage:lifecycleStage,Reason:statusReason}' --output table

# 2. The hook rejected it for the RIGHT reason — the message names both digests.
aws logs tail "/aws/lambda/$POST_TEST" --since 15m --format short | grep -i 'HookRejected\|BGD_EXPECT_DIGEST'

# 3. ZERO production traffic shifted: the production rule never left its colour.
aws elbv2 describe-rules --rule-arns "$PROD_RULE" \
  --query 'Rules[0].Actions[0].ForwardConfig.TargetGroups[?Weight>`0`].TargetGroupArn' --output text
```

The third is the criterion, and it must be sampled *through* the deployment
rather than read afterwards — a rule that moved and moved back would look
identical at the end. Sample every ten seconds from before the trigger.

**Captured 2026-09-01** —
[`docs/evidence/phase-06-exit-criterion-3.txt`](../evidence/phase-06-exit-criterion-3.txt):

```
TIME       blueTG greenTG :443           :8443          prodRule→  testRule→
15:16:39   0      2       0.1.3-caa0d21  0.1.3-caa0d21  green      green
15:17:49   2      2       0.1.3-caa0d21  0.1.3-caa0d21  green      blue    ← incoming isolated on :8443
15:18:45   2      2       0.1.3-caa0d21  0.1.3-caa0d21  green      green   ← rejected, test rule withdrawn
```

`prodRule` reads `green` in **every** sample. The incoming revision was built,
registered in blue and exposed on the test listener alone; the hook rejected it;
it never received a single production request.

The hook's message names both digests, which is what makes the check real rather
than a toggle:

```
HookRejected: /version reports image_digest sha256:b477abea…,
              but BGD_EXPECT_DIGEST is sha256:0000000000…
```

And ECS's operator-facing reason is still the parse error, not the rejection:

```
Service deployment rolled back because POST_TEST_TRAFFIC_SHIFT lifecycle hook(s)
failed. ECS was unable to parse the response … due to: HookStatus must not be null
```

That is the known cost of the raise-rather-than-return asymmetry (plan §D3), now
observed against a *deliberate* rejection rather than an accidental one. Whether
to trade it for a returned `{"hookStatus": "FAILED"}` is Phase 11's decision, and
this is the evidence it was waiting for.

### Then unset it — **do not skip this**

```bash
aws lambda update-function-configuration \
  --function-name "$POST_TEST" \
  --environment "Variables={BGD_STAGE=POST_TEST_TRAFFIC_SHIFT,BGD_PROBE_URL=$TEST}"

aws lambda wait function-updated-v2 --function-name "$POST_TEST"

# Prove it is gone.
aws lambda get-function-configuration --function-name "$POST_TEST" \
  --query 'Environment.Variables' --output json
```

**Left set, `BGD_EXPECT_DIGEST` breaks every subsequent deployment in a way that
looks exactly like a broken build**, and `terraform apply` will not silently fix
it — Terraform never manages this variable, so it is invisible in every plan.
Confirm the next deployment succeeds before you walk away.

---

## 15. Teardown

```bash
make teardown
```

`prod` is destroyed **first**, then `staging`, then `network` — order matters,
because destroying `network` first would strand the ALBs and services that
depend on its subnets and fail part-way, leaving the expensive half running.

**What survives:** `foundation` and `bootstrap`. The hosted zone, the
certificate, the ECR repository and its images, the artifact bucket, the SNS
topic and its confirmed subscription, and the state bucket. That is the whole
reason they are separate layers — a rebuild recreates the `api` record pointing
at a new ALB and the hostname keeps working with no manual step.

**What does not:** the ALB and both target groups, all three listeners and both
rules, the ECS cluster, service and task definition, both DynamoDB tables **and
everything in them**, all three Lambda functions and their log groups, the
application log group, the four alarms, and the `api` A record.

Keep `docs/evidence/phase-06-exit-criterion-2.txt` and the hook log excerpts
from steps 9 and 14 — they are the only durable record of a deployment that no
longer exists.

---

## 16. What goes wrong

| Symptom | Cause |
|---|---|
| Apply fails at `aws_iam_role_policy_attachment.bluegreen`: policy does not exist | The managed policy name. Step 3 exists to catch this before the apply; the plan's §6 has the inline fallback. |
| Plan fails in `data.aws_ecr_image` | `image_tag` is not in ECR. `make seed-ecr`, or pick a tag from step 1. |
| `make teardown` fails inside `data.aws_ecr_image` before destroying anything | The pinned tag aged out of ECR's 10-image retention. Set `image_tag` to a tag that still exists and re-run. |
| Apply fails: *target group does not have an associated load balancer* | The `depends_on` in `ecs.tf` lost a listener. It names both listeners **and both rules** for this reason. |
| Apply fails naming `production_listener_rule` | A **listener** ARN was passed where a **rule** ARN belongs (Phase 0 A7). The message names the attribute, not the reason. |
| `terraform validate` fails on `bake_time_in_minutes` | It is typed **string**. `tostring(var.bake_time_minutes)`, not the number. |
| Deployment stuck in `TEST_TRAFFIC_SHIFT` for many minutes | Green never became healthy. Check the task's stopped reason and the blue/green role's permissions — a rule rewrite that half-succeeded leaves neither colour cleanly owning the listener. `aws ecs stop-service-deployment` to abort. |
| A hook times out at 90s | Almost always `/ready` against unreachable DynamoDB — Phase 5 measured 25.6s to fail, and the handler floors `/ready` at 30s for exactly that. Check the task role and the gateway endpoint's route table association. Do **not** shorten the timeout. |
| A hook rejects with `no connection to …:8443 after 3 attempts` | The transport genuinely never opened, three times over ~24s. That is not the flakiness the retry was added for — check the ALB security group's `:8443` ingress and that the listener exists. A *single* slow handshake no longer rejects anything. |
| `POST_TEST_TRAFFIC_SHIFT` reports the **outgoing** revision's tag | The colours are not separated. Check that both `aws_lb_listener_rule` resources in `alb.tf` still carry `ignore_changes = [action]`, then `aws cloudtrail lookup-events` for `ModifyRule` calls made by `app-deploy-prod-role` or `infra-apply-role`. There should be none. See [the record](../phases/phase6/2026-08-31-blue-green-does-not-isolate.md) §7. |
| `PRE_SCALE_UP` logs a WARNING saying `:443` *is not serving yet* on a deployment that is **not** a create | Something has pointed the production listener at an empty target group. Until 2026-09-01 that was Terraform reverting the rule on every apply, and the line was at INFO where nobody saw it. |
| Every deployment rejected at `POST_TEST_TRAFFIC_SHIFT`, logs mention a digest | `BGD_EXPECT_DIGEST` was left set at step 14. Unset it. This looks exactly like a broken build. |
| An alarm sits in `INSUFFICIENT_DATA` forever | Expected for the *idle* colour's `UnHealthyHostCount` — that is why `treat_missing_data = "notBreaching"` is set (plan §F3). Not expected for the two LoadBalancer-scoped alarms once traffic exists. |
| A deployment rolls back during `BAKE_TIME` with no obvious error | An alarm fired. `describe-alarms --state-value ALARM` names which. If it is the p95 and the build is fine, the threshold is too tight — it was chosen, not measured (step 10). |
| `make apply-prod` hangs past 20 minutes | `wait_for_steady_state` is doing its job and the service is not stabilising. Look at the deployment's stage in terminal B, not at Terraform. Ctrl-C leaves the deployment running — abort it with `stop-service-deployment`, do not just re-apply. |
| `/version` reports `image_digest: unknown` | `BGD_IMAGE_DIGEST` is absent from the container environment. Exit criterion 2 becomes unprovable. |
| Tasks untagged in the console | `propagate_tags` was dropped. `terraform plan` will not show it, and production runs twice as many tasks as staging. |
