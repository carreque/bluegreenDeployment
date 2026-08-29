# Phase 6 — Production environment with native blue/green: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-28
**Status:** Proposed, awaiting approval
**Branch:** `feat/Phase6_ProdBlueGreen`
**AWS cost incurred by this phase as planned:** **$0.** Every deliverable is written and verified locally — Terraform against mocked providers, the Lambda handler against a patched `urlopen`. The applies that create roughly $40/month of real resources are handed to you as a runbook — see §0.1 D1.
**Companion documents:**
[design research](../../2026-08-04-blue-green-deployment-platform-design-research.md) ·
[phase roadmap](../../2026-08-04-implementation-phase-roadmap.md) ·
[Phase 0 findings](../phase0/2026-08-04-phase-00-verification-findings.md) ·
[Phase 4 plan](../phase4/2026-08-26-phase-04-implementation-plan.md) ·
[Phase 5 plan](../phase5/2026-08-28-phase-05-implementation-plan.md) ·
[Phase 5 runbook](../../runbooks/phase-05-staging.md) ·
[naming and tagging convention](../../naming-and-tagging-convention.md)

**Goal:** Write the `prod` environment layer — an ALB with a `:443` production listener and a `:8443` test listener over two target groups, an ECS service running `deployment_configuration { strategy = "BLUE_GREEN" }` with three Lambda lifecycle hooks and a five-minute alarm-gated bake, the production DynamoDB tables, and the `api.carloscloudengineer.com` record — and prove it correct offline before a single resource is created.

This is the roadmap's technical centre. Everything blue/green does *not* change was debugged in Phase 5; this phase adds only the parts that are genuinely about deployment strategy.

**Architecture:** A flat root module at `infra/environments/prod/`, matching the four layers before it, reading `terraform_remote_state` from both `foundation` and `network` exactly as `staging` does. Two new things appear that no previous layer has: a reusable Terraform module at `infra/modules/lambda/`, and Python source outside `app/` at `lambdas/`. Correctness is asserted by Terraform's native test framework against `mock_provider` plus a pytest suite for the handler; the whole gate stays offline.

**Tech stack:** Terraform 1.15.7, AWS provider 6.61.0, `hashicorp/archive` (new to this phase), Python 3.14 for the Lambda runtime, tflint 0.60.0 with AWS ruleset 0.44.0, checkov 3.3.13 — the last two from digest-pinned containers, installing nothing on the host.

**Spec:** [phase roadmap §3, Phase 6](../../2026-08-04-implementation-phase-roadmap.md#phase-6--production-environment-with-native-bluegreen), elaborated by [design research §5 and §7](../../2026-08-04-blue-green-deployment-platform-design-research.md#7-bluegreen-and-rollback) and constrained by [Phase 0's A6 and A7 findings](../phase0/2026-08-04-phase-00-verification-findings.md#a6--does-aws_ecs_service-expose-deployment_configuration-and-lifecycle_hook).

---

## Global Constraints

Project-wide requirements. Every task's requirements implicitly include this section.

- **Naming:** `bgd-us-east-1-<env>-<resource>`, all lowercase, hyphen-separated. ALB and target group names are capped at **32 characters**; this layer's longest is `bgd-us-east-1-prod-api-green` at 28. CloudWatch log groups use slashes: `/bgd/us-east-1/prod/api`. See the [convention](../../naming-and-tagging-convention.md).
- **Tagging:** exactly four keys — `environment`, `projectName`, `region`, `owner` — applied through the provider's `default_tags`. This layer's `environment` is `prod`.
- **`propagate_tags = "SERVICE"`** on the ECS service is mandatory, not optional. Omitting it silently leaves every running task untagged while `terraform plan` stays clean, and production runs twice as many tasks as staging. Convention §6.1.
- **`runtime_platform { cpu_architecture = "ARM64" }`** on the task definition. Phase 2 builds `linux/arm64` only; an `X86_64` task definition cannot start this image.
- **`BGD_IMAGE_DIGEST`** in the container environment. It matters more here than in staging: `/version` is the blue/green evidence surface, and this phase's second exit criterion is read directly off it.
- **Terraform:** `required_version >= 1.10`, AWS provider `~> 6.61`, S3 backend with `use_lockfile = true`, no DynamoDB lock table.
- **The offline gate:** `make tf-check` and `make test-lambdas` must both pass on a machine that has never run `aws sso login`.
- **Every checkov finding is either fixed or skipped with a written reason.** A bare skip is not acceptable; the reason names the trade-off.

---

## 0. Purpose and non-goals

`prod` is the environment the whole project exists to demonstrate. Its distinguishing feature is not that it is bigger than staging — it is two tasks rather than one — but that a deployment to it is a *sequence with gates*, not a replacement: green is provisioned alongside blue, validated through a listener no user reaches, promoted, baked under alarms, and abandoned if any of that fails.

**This phase deliberately does not:**

- create any AWS resource, or make any AWS API call, in this session (D1)
- create a pipeline, or automate the image push — Phases 7 and 8. The blue/green deployment is exercised by hand first, because debugging a blue/green deployment through a pipeline you are simultaneously debugging is a bad trade (roadmap, Phase 6)
- create the CloudWatch dashboard, the EventBridge rules or the metrics Lambda — Phase 9. The four alarms this phase creates exist so ECS can roll back, not so anyone is notified (D9)
- prepare the genuinely broken commit or capture the rollback evidence — Phase 11
- change anything under `app/`, `infra/bootstrap/`, `infra/foundation/`, `infra/network/` or `infra/environments/staging/`

### 0.1 Decisions taken before this plan was written

#### D1 — This session writes and verifies; you apply

The same split Phases 3, 4 and 5 took, for the same reason: no AWS session is available, and the project's working practice is to write and verify every phase offline and execute at the end.

Everything in §4 is verifiable with no AWS credentials. The applies that create the resources, the manual blue/green deployment, and the two demonstrations that need a running service are handed over as [the runbook](../../runbooks/phase-06-prod-blue-green.md).

**None of the three exit criteria in §5 is met by the branch alone.** The plan says so explicitly rather than letting the pull request blur it.

#### D2 — One handler, three functions

All three lifecycle hooks do the same job: probe an HTTP endpoint and report pass or fail. They differ only in which listener they probe and at which stage they run. So `lambdas/lifecycle_hook/handler.py` is written once and the module instantiates it three times, differing only in environment variables.

| Function | Stage | Probes | What it rules out |
|---|---|---|---|
| `bgd-us-east-1-prod-pre-scale-hook` | `PRE_SCALE_UP` | `:443` | Starting a deployment into an already-broken environment. Without this check, a failure during the deployment is ambiguous — was it the new build, or was production already down? |
| `bgd-us-east-1-prod-post-test-hook` | `POST_TEST_TRAFFIC_SHIFT` | `:8443` | The dark canary. A green revision that starts but cannot reach DynamoDB, or serves the wrong image, is rejected before one user request touches it. |
| `bgd-us-east-1-prod-post-prod-hook` | `POST_PRODUCTION_TRAFFIC_SHIFT` | `:443` | Green is now serving real traffic through the production listener; confirm the promotion actually worked before the bake begins. |

The alternative — three separate handler files — would triple the code under test to express one behaviour three times. The alternative in the other direction — one function subscribed to all three stages — is possible (`lifecycle_stages` is a list) but loses the per-stage log group, the per-stage failure message, and the ability to point one stage at a different port.

`/ready` is in the probe set deliberately, and it is the check that carries the dark canary's weight. `/health` reports only that the process is alive; `/ready` performs a real DynamoDB call. A green task that starts but cannot reach its table passes `/health` and fails `/ready`, and that is exactly the failure this hook exists to catch before promotion.

#### D3 — The handler raises on failure and returns on success

The exact contract ECS expects back from a lifecycle hook — a payload such as `{"hookStatus": "SUCCEEDED"}` versus a normal return, and a payload such as `{"hookStatus": "FAILED"}` versus a thrown exception — is **not in the provider schema** and cannot be confirmed without an AWS session. See F2.

Guessing wrong is not symmetric:

- If ECS reads a `hookStatus` field and the handler raises on failure, ECS sees a Lambda invocation error. No plausible contract reads an invocation error as success. **Safe.**
- If ECS treats any successful invocation as a pass and the handler returns `{"hookStatus": "FAILED"}`, the bad build is **promoted to production**. This is the failure the entire phase exists to prevent.

So the handler does both, and is correct under either contract:

- **on success** — returns `{"hookStatus": "SUCCEEDED"}`
- **on failure** — raises `HookRejected`, rather than returning a `FAILED` payload

The asymmetry is the design, not an oversight. The runbook confirms the real contract at first invocation and the plan records what to change if it turns out to be narrower than assumed — but the handler is already correct in the direction that matters.

#### D4 — Seven IAM roles, not six

Phase 0 found that design §8.1's list of five was missing one: `load_balancer.advanced_configuration.role_arn`, the role ECS assumes to rewrite ALB listener rules during a traffic shift. Inspecting the same schema for this plan turns up a **second** required role slot that neither document names: `deployment_configuration.lifecycle_hook.role_arn`.

They are not interchangeable. One needs `elasticloadbalancing` permissions on listener rules; the other needs `lambda:InvokeFunction` on three functions. Design §8.1's stated premise is "least-privilege roles, separated by function", and merging them would give the rule-rewriter permission to invoke arbitrary Lambdas and the invoker permission to rewrite production routing.

This layer therefore creates five roles:

| Role | Assumed by | Grants |
|---|---|---|
| `bgd-us-east-1-prod-task-exec-role` | `ecs-tasks.amazonaws.com` | ECR pull, log stream write — copied from staging |
| `bgd-us-east-1-prod-task-role` | `ecs-tasks.amazonaws.com` | The application's six DynamoDB calls — copied from staging |
| `bgd-us-east-1-prod-bluegreen-role` | `ecs.amazonaws.com` | Rewrite this ALB's listener rules (D5) |
| `bgd-us-east-1-prod-hook-invoke-role` | `ecs.amazonaws.com` | `lambda:InvokeFunction` on exactly the three hook functions |
| `bgd-us-east-1-prod-hook-exec-role` | `lambda.amazonaws.com` | Write to the three hook log groups. Nothing else. |

Design §8.1's six become **seven** across the project, once Phases 7 and 8 add CodeBuild and CodePipeline. The design document is amended in Task 11.

#### D5 — The blue/green controller role uses the AWS-managed policy

`bgd-us-east-1-prod-bluegreen-role` attaches `AmazonECSInfrastructureRolePolicyForLoadBalancers` rather than a hand-written action list.

This is the one place in the project where a hand-rolled least-privilege policy is the *worse* choice. The action set ECS uses to rewrite listener rules mid-shift is not documented in the provider schema and cannot be read offline. A policy that is slightly too narrow does not fail at apply; it fails **halfway through a production traffic shift**, in the window where neither colour cleanly owns the listener.

The failure mode of getting the managed policy's *name* wrong is the opposite and entirely benign: `terraform apply` fails immediately with a "policy does not exist" error, before creating anything. The runbook has an `aws iam get-policy` step that catches it before the apply, and §6 records the fallback.

#### D6 — The hooks are not VPC-attached

The production ALB is internet-facing and `network` already opens `:8443` on the prod ALB security group to `0.0.0.0/0` (F6). The hooks reach both listeners over the public internet.

Attaching them to the private subnets would buy nothing — the endpoints they probe are public either way — and would cost an ENI per concurrent execution, an ENI attachment delay on cold start inside a synchronous deployment gate, and a NAT dependency for a function whose whole job is to run when the deployment is in a fragile state.

checkov disagrees (`CKV_AWS_117`). The skip carries this reason.

#### D7 — ALB access logging stays off for production too

[Phase 5's D5](../phase5/2026-08-28-phase-05-implementation-plan.md) turned this off for staging and explicitly deferred the production decision to this phase, on the grounds that "access logs are genuine blue/green evidence" there. Having looked at what the evidence actually needs to be, the answer is still off.

- The evidence this phase's exit criteria demand is `/version` on `:443` versus `:8443` **during** a deployment, the ECS deployment-stage transitions, and the hook Lambdas' own log output. All three are available within seconds.
- ALB access logs are delivered to S3 on a roughly five-minute lag. That is longer than the deployment they would be evidence of. They would arrive after the thing they document has finished.
- Enabling them requires a bucket policy granting the regional ELB log-delivery principal, which means editing `foundation` — a layer this phase is scoped not to touch — or creating a bucket in `prod`, which `make teardown` destroys along with every log in it.

Recorded rather than silently repeated, because Phase 5 explicitly promised this phase would decide again.

#### D8 — Bake alarms are LoadBalancer-scoped, except the one that cannot be

`deployment_configuration.alarms.alarm_names` is a static list. Terraform cannot know which target group will be green at deploy time, so the dimension choice is forced rather than a matter of taste.

- **`HTTPCode_Target_5XX_Count` and `TargetResponseTime`** carry the `LoadBalancer` dimension only. They then measure what users actually experience, which is the rollback criterion. Scoping them per target group would also trip on the *old* group's errors as it drains, which is not a reason to roll back a promotion that already happened.
- **`UnHealthyHostCount`** has no LoadBalancer-only form — CloudWatch publishes it per target group (F3). So it takes two alarms, one per group, both listed in `alarm_names`.

Four alarms in total. `treat_missing_data = "notBreaching"` on all four, and that setting is load-bearing rather than cosmetic: the idle target group publishes no `UnHealthyHostCount` at all, so the default would park that alarm permanently in `INSUFFICIENT_DATA`.

Periods are 60 seconds with one or two datapoints. That is also forced: a five-minute bake cannot be gated by an alarm that needs five minutes to evaluate.

**The thresholds are chosen, not measured** — 5 target-5xx responses in a minute, a 2-second p95, one unhealthy host. They are stated here as chosen so that nobody later mistakes them for empirical. The runbook's step 10 records the real numbers under real traffic, and adjusting them is a one-line change.

#### D9 — The alarms carry no `alarm_actions`

They exist so ECS can roll back, not so anyone is emailed. Phase 9 owns notification, has the SNS topic in `foundation` already, and will attach actions to these same alarms rather than creating parallel ones.

Attaching SNS here would also send mail on every deliberate demonstration in Phases 6 and 11, training the recipient to ignore the topic before it carries a real alert.

#### D10 — Terraform initiates the deployment; the CLI observes it

The roadmap says blue/green is "exercised here by hand via the AWS CLI". Read literally that would mean `aws ecs update-service --task-definition …`, and that is the one thing this project must not do: Terraform owns the task definition and the service shape, and design §1.5's entire argument for why the CodePipeline ECS action's image-only limitation is a non-issue rests on that ownership. A CLI `update-service` would register drift that the next `terraform apply` reverts, mid-deployment.

So the split is:

- **Terraform initiates** — change `image_tag` in `terraform.tfvars`, run `make apply-prod`. The new task definition revision is registered and the service updated, and ECS begins the blue/green deployment.
- **The CLI observes and intervenes** — `aws ecs list-service-deployments` and `describe-service-deployments` for the stage transitions, `curl` on both listeners for the evidence, and `aws ecs stop-service-deployment` if a deployment needs aborting by hand.

This is by hand and it is via the CLI, which is what the roadmap's intent requires. The runbook says it in these words so the next reader does not think a step was skipped.

#### D11 — `wait_for_steady_state = true` on the production service

Without it, `terraform apply` returns success the moment ECS accepts the deployment. Every part of blue/green that matters — the hooks, the traffic shift, the bake, an alarm rollback — then happens *after* Terraform has already reported success, and a rolled-back deployment leaves a green plan and a red service.

On the one layer whose entire purpose is deployment safety, an apply that cannot fail when the deployment fails is the wrong default.

**The trade, stated:** a production apply takes six to ten minutes instead of returning immediately, and Phase 7's pipeline apply stage inherits that duration. Accepted — a pipeline stage that finishes before the deployment it triggered has succeeded is not a gate.

Staging deliberately does **not** get this. Its job is to fail fast and its circuit breaker already reverts it; blocking an apply for the sake of a one-task environment buys nothing.

#### D12 — `BGD_EXPECT_DIGEST` is an optional stricter assertion, not a failure toggle

The third exit criterion needs a hook to fail on purpose. A boolean `FORCE_FAIL` environment variable would satisfy it and would be dishonest: nothing about the deployment would actually be wrong, and Phase 11's evidence standard — "a genuinely broken commit, not a simulated failure toggle" — would be violated one phase early.

Instead the handler honours an optional `BGD_EXPECT_DIGEST`. When unset, which is how Terraform deploys it, the post-test hook asserts liveness and logs the digest it saw. When set, it additionally asserts that `/version`'s `image_digest` equals that value.

The runbook sets it to a bogus digest with one `aws lambda update-function-configuration` call, deploys, and watches a **real check fail against a wrong expectation** — then unsets it. The check is genuine; only the expectation is deliberately wrong. Terraform never sets the variable, so there is no toggle in the committed infrastructure to forget about.

The variable is also independently useful: Phase 8's pipeline knows the digest it just pushed and can set it per deployment, turning the dark canary into a full "the thing I built is the thing serving" assertion. Noted, not built here.

#### D13 — Production runs two tasks, and both DynamoDB tables are in scope

Two decisions the roadmap's Phase 6 task list does not state, both taken from documents that do.

- **`desired_count = 2`.** Design §10 prices "Fargate (staging 1 task, prod 2 tasks)". Two tasks across two availability zones is also the minimum that makes `UnHealthyHostCount` a meaningful alarm rather than a synonym for "the service is down".
- **The DynamoDB tables are in this layer.** Roadmap §1's layer diagram lists `DynamoDB` under `envs/prod/`; the Phase 6 task list omits it. The application cannot serve `/ready`, let alone a transaction, without its tables, so the diagram is right and the task list is incomplete. Amended in Task 11.

The tables are `staging`'s file with the prefix changed. They are not shared with staging, and that is the point of environment separation.

#### D14 — A `lambda` module, and Python source outside `app/`

Design §9's repository layout puts lifecycle hooks at `/lambdas`, and `.gitignore` already anticipates it (`!lambdas/**/fixtures/*.zip`). `infra/modules/lambda/README.md` already exists and already promises exactly this module, naming the three hooks and the `python3.14` runtime.

So neither location is a new invention; this phase fills in two placeholders the earlier phases left.

The module owns four things per function: the `archive_file`, the `aws_lambda_function`, its log group, and its execution role and policy. Three near-identical instantiations in this layer plus Phase 9's metrics collector is enough repetition to justify it — and `infra/modules/README.md` states the project's rule that modules are added by the phase that needs them, which is now.

**The handler uses only the standard library** — `urllib.request` and `json`, no `boto3`, no HTTP client dependency. That is what keeps the packaging trivial: the zip is one file, `data.archive_file` builds it during `terraform test` with no network access, and the pytest suite needs nothing the existing virtualenv does not already have.

---

## 1. Findings recorded before this plan was written

Each of these changed the plan. Findings that only confirmed something already assumed are not listed.

### F1 — The full blue/green surface, re-confirmed against the installed provider binary

Phase 0 established this against provider 6.57.1 and Phase 5's F7 re-checked it at 6.61. It is checked a third time here, because this is the phase that actually depends on every attribute, and because a plan that writes `hook_target_arn` from memory is a plan that discovers a rename at apply time.

Method: an empty scratch module pinned to `6.61.0` with `infra/environments/staging/.terraform.lock.hcl` copied in, then `terraform providers schema -json`. This reads the binary in the lock file, not a changelog.

```
aws_ecs_service.deployment_configuration        list, max 1
  strategy                   string   optional + computed
  bake_time_in_minutes       string   optional + computed
  lifecycle_hook             SET
    hook_target_arn          string   REQUIRED
    lifecycle_stages         list(string)   REQUIRED
    role_arn                 string   REQUIRED
    hook_details             string   optional
  canary_configuration       list, max 1
  linear_configuration       list, max 1

aws_ecs_service.load_balancer.advanced_configuration   list, max 1
  alternate_target_group_arn string   REQUIRED
  production_listener_rule   string   REQUIRED
  role_arn                   string   REQUIRED
  test_listener_rule         string   optional

aws_ecs_service.alarms                          list, max 1
  alarm_names                set(string)   REQUIRED
  enable                     bool     REQUIRED
  rollback                   bool     REQUIRED
```

**Consequences this plan takes:**

- `lifecycle_hook` is a **set** nested inside `deployment_configuration`, not a top-level block and not a list. Three members, one per stage.
- `bake_time_in_minutes` is typed **string**. `"5"`, not `5`.
- `advanced_configuration` is nested inside a **single** `load_balancer` block. Blue/green is not two `load_balancer` blocks — one names the production target group in `target_group_arn`, the other target group goes in `alternate_target_group_arn`.
- `production_listener_rule` and `test_listener_rule` are **rule** ARNs. Both listeners need an `aws_lb_listener_rule`; a default listener action will not do. This is Phase 0's finding and it is why §3 has listener rules in `alb.tf`.
- `alarms.enable` and `alarms.rollback` are both **required** booleans — there is no "just list them" form.
- `strategy` is `optional + computed`, so writing `"BLUE_GREEN"` is what makes the difference from staging's explicit `"ROLLING"` visible in the diff rather than implied.

`canary_configuration` and `linear_configuration` exist and are deliberately unused — see the note in §2.

### F2 — The hook response contract is not in the schema and cannot be confirmed offline

The schema describes how ECS is told *which* Lambda to invoke. It says nothing about what the Lambda must return for ECS to treat the stage as passed, because that is a runtime API contract rather than a Terraform resource attribute.

There is no local source of truth for it — not the provider schema, not the AWS CLI's local models, and not anything in this repository. Confirming it needs a real invocation.

**This is the single largest unverified assumption in the phase**, and D3 is the response: the handler is built to be correct under either plausible contract rather than betting on one. The runbook's step 9 reads the hook's CloudWatch log after the first real deployment and records what ECS actually did with the return value, which retires the finding.

### F3 — `UnHealthyHostCount` is published per target group, which forces two alarms

Reasoned from CloudWatch's published ALB metric dimensions rather than measured, and flagged as such: the metric's dimension set is `TargetGroup` + `LoadBalancer`, with no LoadBalancer-only aggregate, because "unhealthy" is a property of a target's registration in a group rather than of the load balancer.

If this is wrong, the correction is small and visible — one alarm instead of two, caught the first time the runbook looks at the alarm's state. If it is right and the plan had assumed otherwise, the alarm would sit in `INSUFFICIENT_DATA` forever and silently contribute nothing to the bake gate, which is the worse direction. Two alarms is the choice that fails visibly.

The runbook's step 10 checks both alarms leave `INSUFFICIENT_DATA` once traffic exists.

### F4 — `mock_provider "aws"` does not touch `data.archive_file`, so the zip is really built

`mock_provider` mocks one provider. `archive` is a different provider, so during `terraform test` the `archive_file` data source executes for real and produces an actual zip on disk from `lambdas/lifecycle_hook/handler.py`.

This is a benefit, not a problem: the offline gate genuinely proves the packaging works, rather than mocking away the step most likely to be misconfigured. It also means `terraform test` fails loudly if the handler path is wrong — which is the correct behaviour and could not be achieved with a mocked data source.

It has one consequence for Task 1: the prod layer's `.terraform.lock.hcl` must include `hashicorp/archive`, and `scripts/tf.sh` initialises with `-backend=false` for `validate` and `test`, which still downloads providers. So the first `./scripts/tf.sh test prod` needs network access to the registry once, exactly as every previous layer's first run did. It needs no AWS credentials.

### F5 — `/version` carries `git_sha`, so the second exit criterion needs two commits

`app/src/bgd/api/routers/health.py` returns `version`, `git_sha` and `image_digest`, and `app/src/bgd/config.py` sets all three from `BGD_`-prefixed environment variables baked in at image build time.

The exit criterion is "`/version` returns different SHAs on `:443` and `:8443` mid-deployment". `git_sha` is fixed inside the image, so producing two different values requires **two images built from two different commits** — the seeded image from Phase 3, and a second one built after a trivial `app/` change.

That is a runbook step, not something this layer can provide, and it must happen *before* the deployment that demonstrates the criterion. The runbook orders it accordingly. Phase 2's build is reproducible from the commit, so a new commit reliably produces a new digest and a new SHA.

### F6 — `network` already carries everything production needs; this phase never reopens it

Confirmed by reading `infra/network/security.tf` and `infra/network/outputs.tf`:

- `aws_security_group.alb` and `aws_security_group.task` are both `for_each` over `toset(["staging", "prod"])`, so the production pair already exists.
- `aws_vpc_security_group_ingress_rule.alb_test` opens `:8443` on the **prod** ALB group only, with the comment "this is the test listener the blue/green deployment shifts traffic to … the reason Phase 6 never has to reopen this layer."
- `alb_security_group_ids` and `task_security_group_ids` are exported as maps keyed by environment, and `container_port` (8080) is exported so this layer cannot disagree with the rules opened there.

Phase 4's D3 decision to build four security groups rather than two shared ones is what makes this true. Nothing in `infra/network/` changes in this phase.

### F7 — checkov will fail this layer on the Lambda checks, and the reasons differ from Phase 5's

Predicted from checkov 3.3.13's rule set and the shapes this layer introduces; the real list is captured in Task 9 and the local verification record, and any prediction that turns out wrong is corrected there rather than left standing.

Carried over from Phase 5 with the same reasons, now applied to production: ALB deletion protection (`CKV_AWS_150`, teardown), ALB access logging (`CKV_AWS_91`, D7), WAF (`CKV2_AWS_28`), DynamoDB point-in-time recovery (`CKV_AWS_28`) and CMK (`CKV_AWS_119`), log group retention (`CKV_AWS_338`) and log group KMS (`CKV_AWS_158`).

New to this phase, from the Lambda functions: X-Ray tracing, a dead letter queue, reserved concurrency, code signing, VPC attachment (`CKV_AWS_117`, answered by D6) and CMK-encrypted environment variables. Each needs its own written reason — a synchronous deployment gate that runs three times per deployment and holds no secrets is a different risk profile from a general-purpose Lambda, and the skips must say that rather than pointing at Phase 5.

**A skip that only says "as above" is not acceptable here.** Production is the layer where a reviewer is most entitled to see the reasoning in full.

### F8 — Every production name fits, with room to spare

The 32-character cap applies to ALB and target group names, and the convention document already worked this out for the worst case in the whole design.

| Name | Length | Cap |
|---|---|---|
| `bgd-us-east-1-prod-alb` | 22 | 32 |
| `bgd-us-east-1-prod-api-blue` | 27 | 32 |
| `bgd-us-east-1-prod-api-green` | 28 | 32 |
| `bgd-us-east-1-prod-hook-invoke-role` | 35 | 64 (IAM) |
| `bgd-us-east-1-prod-post-test-hook` | 33 | 64 (Lambda) |

`bgd-us-east-1-prod-api-green` at 28 is the longest name the project produces, and it is the name the convention's §1 worked the `bgd` prefix out from. No truncation is needed anywhere.

**One deviation to record:** the hook Lambdas' log groups are `/aws/lambda/<function-name>`, not the convention's `/bgd/us-east-1/prod/<service>`. That prefix is what Lambda writes to unless a `logging_config` block redirects it, and every console path, sample query and AWS tool assumes it. Deviating would gain consistency in a naming document and lose it everywhere an operator actually looks. Amended into the convention in Task 11.

---

## 2. Global constraints

Restating the ones this layer breaks if it gets them wrong, with the symptom attached. The first four are inherited from Phase 5 and still apply; the rest are new.

| Constraint | Symptom if missed |
|---|---|
| `runtime_platform { cpu_architecture = "ARM64" }` | Tasks fail at start with an exec format error. In a blue/green deployment green never becomes healthy, the deployment stalls, and `wait_for_steady_state` eventually times the apply out. |
| `BGD_IMAGE_DIGEST` in the container environment | `/version` reports `unknown`. Exit criterion 2 becomes unprovable and the post-test hook's optional digest assertion can never pass. |
| `propagate_tags = "SERVICE"` | Two production tasks untagged, plus the green task set during every deployment. Fargate cost unattributable, `terraform plan` clean. |
| Task role policy includes the LSI index ARN and the write actions | `GET /api/transactions` and `POST /api/transactions` fail `AccessDenied` at runtime; `/health` and `/ready` still pass, so the hooks promote the build. |
| `bake_time_in_minutes` is a **string** | `terraform validate` fails. Loud and immediate — the harmless one on this list. |
| `production_listener_rule` is a **rule** ARN | Passing a listener ARN is an apply-time failure with a message that names the attribute but not the reason. |
| `advanced_configuration.role_arn` and `lifecycle_hook.role_arn` are both required | The service cannot be created at all. Two different roles (D4). |
| `alarms { enable, rollback }` both set | Omitting the block means the five-minute bake observes nothing and rolls back on nothing. The deployment still succeeds, so the gap is silent. |
| `treat_missing_data = "notBreaching"` on the unhealthy-host alarms | The idle target group's alarm sits in `INSUFFICIENT_DATA`, and whether ECS treats that as breaching is not something to find out during a production shift. |
| Both listener rules have a `/*` condition and a priority | An `aws_lb_listener_rule` without a condition is invalid; without a priority two rules collide. |
| `depends_on` covering the listeners and both role policies | The same ordering trap Phase 5 documented, doubled: ECS refuses a service whose target group has no load balancer, and IAM is eventually consistent. With `wait_for_steady_state` the failure is at least loud rather than a green apply over a dead service. |
| Hooks reachable from the public internet | A VPC-attached hook (D6 rejected this) would need NAT egress to reach its own ALB, and would fail closed during exactly the deployments it is meant to gate. |

**`canary_configuration` and `linear_configuration` are deliberately unused.** Both exist in the provider (F1) and both are tempting. Neither is in the design, and a percentage-based shift would blur exit criterion 2: the evidence is that `:443` and `:8443` serve *different* SHAs at the same moment, which is cleanest when the production listener is entirely one colour. Recorded here so the omission reads as a decision rather than an oversight.

---

## 3. File structure

```
lambdas/
  README.md                      what these are, and the D3 contract
  pyproject.toml                 own pytest, ruff and coverage config
  lifecycle_hook/
    handler.py                   one handler, stdlib only
  tests/
    test_handler.py              urlopen patched; no network, no AWS

infra/modules/lambda/
  versions.tf                    aws + archive provider constraints
  variables.tf                   name, handler source, env, retention
  main.tf                        archive_file, function, log group, role, policy
  outputs.tf                     function_arn, function_name, log_group_name
  README.md                      exists; updated to describe the built module

infra/environments/prod/
  versions.tf                    terraform block, both providers, S3 backend
  providers.tf                   aws provider, allowed_account_ids, default_tags
  variables.tf                   every input, defaults correct for this project
  locals.tf                      both remote states, the ECR lookup, derived names
  dynamodb.tf                    accounts and transactions, LSI included
  iam.tf                         five roles and their policies
  alb.tf                         load balancer, two target groups, three listeners,
                                 two listener rules
  hooks.tf                       three module instantiations
  alarms.tf                      the four bake alarms
  ecs.tf                         log group, cluster, task definition, blue/green service
  dns.tf                         the api A record
  outputs.tf                     the surface Phase 8, 9 and 11 consume
  terraform.tfvars.example       documented, committed; terraform.tfvars is gitignored
  README.md                      what this layer owns and depends on
  tests/
    mocks.tftest.hcl             the reference mock block and remote-state overrides
    data_and_iam.tftest.hcl      tables, LSI, and what all five roles grant
    edge.tftest.hcl              ALB, two target groups, three listeners, two rules, DNS
    bluegreen.tftest.hcl         NEW SHAPE — the deployment_configuration, the three
                                 hooks, advanced_configuration and the alarm wiring
    compute.tftest.hcl           task definition, service basics, Phase 2 inheritances
    outputs.tftest.hcl           the interface later phases depend on

docs/
  runbooks/phase-06-prod-blue-green.md            new
  phases/phase6/
    2026-08-28-phase-06-implementation-plan.md    this document
    2026-08-28-local-verification.md              new — the evidence record

makefile                         TF_LAYERS gains prod; new test-lambdas target;
                                 lint covers lambdas/
```

**Why these boundaries.** `prod` keeps Phase 5's split-by-responsibility — `alb.tf` terminates traffic, `ecs.tf` runs it, `iam.tf` grants it, `dns.tf` isolates the one cross-layer write into `foundation`'s hosted zone — and adds two files for the two things staging has no equivalent of. `hooks.tf` and `alarms.tf` are separate from `ecs.tf` even though the service references both, because they are the parts a reviewer comparing the two environments needs to find, and burying them in a 200-line `ecs.tf` hides the diff that is the whole point of this phase.

`bluegreen.tftest.hcl` is the same argument applied to the tests. Everything in it is new shape with no staging counterpart; everything in `compute.tftest.hcl` is an assertion Phase 5 already makes, re-pointed at this layer.

---

## 4. Tasks

Eleven tasks. Tests precede implementation throughout, which for Terraform means the `.tftest.hcl` file is written and **seen to fail** before the resources it asserts on exist, and for the handler means the pytest suite is written and seen to fail before `handler.py` does anything.

Every task ends with its suite passing and a commit **proposed for approval, never made automatically**. The full gate — `make tf-check` plus `make test-lambdas` — runs at Task 9 and again at Task 11.

---

### Task 1: Layer skeleton, remote state, and the DynamoDB tables

Phase 5's Task 1 with `staging` replaced by `prod`, plus the `archive` provider. The tables come first for the same reason as in staging: the task role's policy interpolates their ARNs, and the LSI cannot be corrected later without destroying the table.

**Files:**
- Create: `infra/environments/prod/versions.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `dynamodb.tf`, `terraform.tfvars.example`
- Test: `infra/environments/prod/tests/mocks.tftest.hcl`
- Test: `infra/environments/prod/tests/data_and_iam.tftest.hcl`
- Delete: `infra/environments/prod/.gitkeep`

**Interfaces:**
- Consumes: `foundation` outputs `certificate_arn`, `zone_id`, `api_domain`, `ecr_repository_url`, `ecr_repository_arn`; `network` outputs `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `alb_security_group_ids`, `task_security_group_ids`, `container_port`.
- Produces: `local.env_prefix` (`bgd-us-east-1-prod`), `local.foundation`, `local.network`, `local.container_port`, `local.container_name` (`"api"`), `local.image_reference`, `local.log_group_name`, `aws_dynamodb_table.accounts`, `aws_dynamodb_table.transactions`.

- [ ] **Step 1: Copy `staging`'s skeleton and change what differs**

Start from `infra/environments/staging/{versions,providers,variables,locals,dynamodb}.tf`. Four things change and nothing else:

1. `versions.tf` — the backend `key` becomes `prod/terraform.tfstate`, and `required_providers` gains `archive = { source = "hashicorp/archive", version = "~> 2.7" }`.
2. `locals.tf` — `local.environment = "prod"`, and `local.foundation.api_domain` replaces `staging_api_domain`.
3. `variables.tf` — `desired_count` defaults to **2**, not 1 (D13), and its description says why. Three new variables: `bake_time_minutes` (default `5`, number, converted to string at the call site), `hook_timeout_seconds` (default `60`, see Task 2 Step 3's arithmetic), `alarm_p95_seconds` (default `2`, consumed by Task 7).
4. `dynamodb.tf` — identical but for the prefix. The LSI, the `deletion_protection_enabled = false`, and both checkov skips carry over verbatim.

The backend block cannot interpolate, so the bucket appears as a literal exactly as in the four layers before it.

- [ ] **Step 2: Write the mock reference file**

`tests/mocks.tftest.hcl`, diffed against `infra/environments/staging/tests/mocks.tftest.hcl`. Every mock staging needs, plus the ones this layer's new resources need:

```hcl
mock_provider "aws" {
  # …every mock_resource block from staging's copy, verbatim…

  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:590184028094:listener/app/mock/0123456789abcdef/aaaaaaaaaaaaaaaa" }
  }

  mock_resource "aws_lb_listener_rule" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:590184028094:listener-rule/app/mock/0123456789abcdef/aaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbb" }
  }

  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:590184028094:function:mock" }
  }

  mock_resource "aws_cloudwatch_metric_alarm" {
    defaults = { arn = "arn:aws:cloudwatch:us-east-1:590184028094:alarm:mock" }
  }
}
```

Add each one **because omitting it produced a hard error**, following Phase 5's F2 discipline — not because it looked tidy. Any mock that turns out to be unnecessary is deleted before the task ends, and the local verification record notes which were actually needed.

`override_data` for both remote states carries over from staging with `staging_api_domain` replaced by `api_domain`.

- [ ] **Step 3: Write the failing table assertions, then the tables**

`tests/data_and_iam.tftest.hcl` starts as staging's table assertions with the prefix changed. Run `./scripts/tf.sh test prod` and **see it fail** before `dynamodb.tf` exists.

- [ ] **Step 4: Run the suite and commit**

```bash
./scripts/tf.sh test prod
```

Commit: `feat(infra): prod layer skeleton, remote state and DynamoDB tables`.

---

### Task 2: The lifecycle hook handler, test-first

The only Python this phase writes, and the first Python outside `app/`. It is written before any Terraform references it, because the module's `archive_file` needs the file to exist and because a handler whose contract is settled makes the module's variables obvious.

**Files:**
- Create: `lambdas/pyproject.toml`, `lambdas/README.md`
- Create: `lambdas/lifecycle_hook/handler.py`
- Test: `lambdas/tests/test_handler.py`
- Modify: `makefile` — add `test-lambdas`, extend `lint`

**Interfaces:**
- Consumes: environment variables `BGD_PROBE_URL` (required), `BGD_STAGE` (required, for log context), `BGD_TIMEOUT_SECONDS` (optional, default 10), `BGD_EXPECT_DIGEST` (optional, D12).
- Produces: `handler(event, context) -> {"hookStatus": "SUCCEEDED"}`, or raises `HookRejected`.

- [ ] **Step 1: Write `lambdas/pyproject.toml`**

Its own config rather than an entry in `app/pyproject.toml`, because app's settings are wrong here: `pythonpath = ["src"]`, `testpaths = ["tests"]` relative to `app/`, and `coverage source = ["src/bgd"]` with `fail_under = 90` all describe the service, not the hooks.

```toml
[project]
name = "bgd-lambdas"
version = "0.0.0"
description = "Blue/green lifecycle hooks and, from Phase 9, the metrics collector"
requires-python = ">=3.14"

# No [build-system]: these are never pip-installed. Lambda unzips handler.py
# next to its own runtime, and the tests reach it through pythonpath below.
# Matches app/pyproject.toml's reasoning exactly.

[tool.pytest.ini_options]
pythonpath = ["."]
testpaths = ["tests"]
addopts = "-q --strict-markers --strict-config --cov --cov-report=term-missing"

[tool.coverage.run]
source = ["lifecycle_hook"]
branch = true

[tool.coverage.report]
fail_under = 95
show_missing = true

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "N", "UP", "B", "A", "C4", "SIM", "RUF", "S", "T20"]

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["S101"]
```

`fail_under = 95`, above app's 90. The handler is one file of roughly eighty lines that gates production deployments; there is no part of it that should go untested.

- [ ] **Step 2: Write `lambdas/tests/test_handler.py` and see it fail**

The suite patches `urllib.request.urlopen`, so it makes no network call and needs no AWS. Cases, each named for the failure it catches:

| Test | Asserts |
|---|---|
| `test_all_probes_pass_returns_succeeded` | Returns `{"hookStatus": "SUCCEEDED"}` when `/health`, `/ready` and `/version` all answer 200 |
| `test_probes_are_the_expected_three_paths` | Exactly `/health`, `/ready`, `/version` are requested, in that order, against `BGD_PROBE_URL` |
| `test_unhealthy_raises_rather_than_returning_failed` | A non-200 on any probe raises `HookRejected` — **this is D3's assertion and the most important test in the file** |
| `test_ready_failure_raises` | A 503 from `/ready` specifically raises, because that is the dark canary's real job |
| `test_timeout_raises` | A `URLError` from `urlopen` raises rather than escaping as an unhandled type |
| `test_digest_match_when_expectation_set` | With `BGD_EXPECT_DIGEST` set to the served digest, returns `SUCCEEDED` |
| `test_digest_mismatch_raises` | With `BGD_EXPECT_DIGEST` set to a different value, raises — the mechanism exit criterion 3 uses |
| `test_no_expectation_ignores_digest` | With `BGD_EXPECT_DIGEST` unset, a served digest of `unknown` still passes liveness. The variable is opt-in (D12) |
| `test_missing_probe_url_raises` | An unset `BGD_PROBE_URL` raises at once rather than probing `None` |
| `test_failure_message_names_path_and_status` | The exception message contains the path and the status code, because a hook rejection's only trace is this string in CloudWatch |

Run and see them fail:

```bash
cd lambdas && ../app/.venv/bin/python -m pytest
```

- [ ] **Step 3: Write `lambdas/lifecycle_hook/handler.py`**

```python
"""ECS blue/green lifecycle hook.

One handler, three deployments of it. Each instance probes one listener at one
stage of the deployment; which listener and which stage come from the
environment, so the code that decides whether a release proceeds exists once.

See docs/phases/phase6/…-implementation-plan.md D2 and D3.

The return contract is deliberately asymmetric. On success this returns
{"hookStatus": "SUCCEEDED"}. On failure it *raises* rather than returning a
"FAILED" payload, because the exact contract ECS expects could not be confirmed
without an AWS session (plan F2) and the two possible mistakes are not equally
bad: a raised exception is an unambiguous invocation error under any contract,
whereas a returned FAILED that ECS does not parse promotes a bad build to
production. Do not "tidy" this into a symmetric return.

Standard library only. No boto3, no HTTP client dependency — which is what makes
the deployment package one file and lets terraform test build it offline.
"""
```

Behaviour, in order:

1. Read `BGD_PROBE_URL` and `BGD_STAGE`; raise `HookRejected` immediately if either is missing.
2. Probe `/health`, `/ready`, `/version` in that order, each with `BGD_TIMEOUT_SECONDS` (default 10). Any non-200, any `URLError`, any timeout raises `HookRejected` naming the path and what happened.
3. Parse `/version`'s body and log `git_sha` and `image_digest` at INFO. This log line is the phase's evidence surface when the deployment is observed after the fact.
4. If `BGD_EXPECT_DIGEST` is set and does not equal the reported `image_digest`, raise `HookRejected`.
5. Return `{"hookStatus": "SUCCEEDED"}`.

`/ready` gets its own timeout allowance. Phase 5's F5 measured `/ready` taking 25.6 seconds to fail when DynamoDB is unreachable, because botocore retries with backoff. A 10-second probe would report a timeout and hide the 503 that names the real cause — on exactly the failure the dark canary exists to catch. So `/ready` uses `max(BGD_TIMEOUT_SECONDS, 30)`.

That sets the Lambda's own timeout by arithmetic rather than by taste. Worst case is three sequential probes — 10s for `/health`, 30s for `/ready`, 10s for `/version` — so 50 seconds of probing. `hook_timeout_seconds` is therefore **60**, not 30: a 30-second function would be killed mid-`/ready` and ECS would see an invocation error, which D3 makes it treat as a rejection. The dark canary would then fail every deployment where DynamoDB was merely slow, which is the opposite of a useful gate.

`event` and `context` are accepted and **not parsed**. Reading the deployment identifiers out of the event would be more informative, but their shape is unverifiable offline (F2) and a handler that raises on an unexpected event shape would fail every deployment. The event is logged raw at INFO instead, which is how the runbook discovers its real shape.

- [ ] **Step 4: Write `lambdas/README.md`**

What these functions are, the three stages, the D3 contract stated plainly for someone who opens the file without the plan, and the note that Phase 9 adds a second package here.

- [ ] **Step 5: Wire the makefile**

```makefile
.PHONY: test-lambdas
test-lambdas: deps ## Run the Lambda handler suite
	@cd lambdas && $(PY) -m pytest
```

`deps` because the suite needs the virtualenv's pytest; `$(PY)` by absolute path for the same reason every Phase 1 recipe does it — `python3` on `PATH` is only 3.14.6 when make's parent was an interactive zsh (Phase 0 §B).

Extend `lint` and `format` to cover `lambdas/` as well as `app/`.

- [ ] **Step 6: Run and commit**

```bash
make test-lambdas && make lint
```

Commit: `feat(lambdas): blue/green lifecycle hook handler, test-first`.

---

### Task 3: The `lambda` Terraform module

**Files:**
- Create: `infra/modules/lambda/versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`
- Modify: `infra/modules/lambda/README.md`

**Interfaces:**
- Consumes: `function_name`, `source_file`, `handler`, `environment` (map), `timeout_seconds`, `log_retention_days`.
- Produces: `function_arn`, `function_name`, `log_group_name`, `role_arn`.

- [ ] **Step 1: Write the module**

Four resources per instantiation:

1. `data.archive_file` — zips `var.source_file` to a path under `${path.module}/.build/`. `output_file_mode = "0644"` so the archive is byte-identical between machines, which keeps `terraform plan` clean rather than showing a permission-driven hash change.
2. `aws_lambda_function` — `runtime = "python3.14"` (Phase 0 A4 confirmed the runtime exists; Phase 0's own caveat is that membership of the enum proves the identifier is *recognised*, and this phase's apply is what confirms it is creatable), `architectures = ["arm64"]` to match the container's Graviton choice and price, `source_code_hash` from the archive so a handler change redeploys.
3. `aws_cloudwatch_log_group` — named `/aws/lambda/${var.function_name}` (F8), created explicitly rather than left to Lambda so retention is managed and the execution role can be scoped to it.
4. `aws_iam_role` + `aws_iam_role_policy` — trust `lambda.amazonaws.com`, grant `logs:CreateLogStream` and `logs:PutLogEvents` on that log group's ARN only. `logs:CreateLogGroup` is deliberately absent, for the reason `staging/iam.tf` already records: granting it lets a typo produce a second, unmanaged group instead of failing.

Policies use `jsonencode`, not `aws_iam_policy_document` — Phase 5's D9 and F1, and it applies identically here.

`depends_on = [aws_cloudwatch_log_group.this]` on the function, so the group Terraform manages exists before Lambda would create one implicitly on first invocation.

- [ ] **Step 2: Update `infra/modules/lambda/README.md`**

The file already describes what this module is *for*. Add what it now *is*: its inputs, its outputs, that it is a single-file packaging module by design, and that Phase 9 reuses it for the metrics collector — with the note that Phase 9 will need a dependency-bearing variant if the collector uses boto3, since `archive_file` over one source file cannot express that.

- [ ] **Step 3: Commit**

Commit: `feat(infra): a single-file Lambda packaging module`.

There is no separate test suite for the module. It has no logic of its own — no conditionals, no `for_each`, no computed names — and Task 5's assertions on the three real instantiations test everything it does. A test suite over a module with no branches asserts that Terraform works.

---

### Task 4: The five IAM roles

**Files:**
- Create: `infra/environments/prod/iam.tf`
- Modify: `infra/environments/prod/tests/data_and_iam.tftest.hcl`

**Interfaces:**
- Produces: `aws_iam_role.task_exec`, `aws_iam_role.task`, `aws_iam_role.bluegreen`, `aws_iam_role.hook_invoke`. The fifth — the hooks' execution role — belongs to the module and is created three times by Task 5.

- [ ] **Step 1: Write the failing assertions**

Extend `tests/data_and_iam.tftest.hcl`. Staging's assertions carry over for the two task roles; three groups are new:

| Assertion | What it protects |
|---|---|
| `bluegreen` role trusts `ecs.amazonaws.com` with an account condition | Without the condition the role is confused-deputy shaped |
| `bluegreen` has exactly one managed policy attachment, and it is `AmazonECSInfrastructureRolePolicyForLoadBalancers` | D5. A future "tighten this" change has to argue with a test |
| `hook_invoke` grants `lambda:InvokeFunction` on exactly three ARNs and nothing else | A wildcard here lets the deployment controller invoke any function in the account |
| `hook_invoke` and `bluegreen` are **different roles** | D4. Asserting the ARNs differ is what stops a later simplification merging them |
| `task` role's policy is one statement with the six actions and three resources | Staging's assertion, re-pointed. Includes the LSI index ARN |

Run `./scripts/tf.sh test prod` and see them fail.

- [ ] **Step 2: Write `iam.tf`**

`staging/iam.tf` copied for the two task roles, with the prefix changed and both long explanatory comments preserved — they are as true here as there, and production is not the place to thin out the reasoning.

Then the two new roles. Both trust `ecs.amazonaws.com`, both with `Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }`, following the pattern the task roles already set.

```hcl
# The role ECS assumes to rewrite this ALB's listener rules during a traffic
# shift. Design §8.1's sixth role, found in Phase 0 — advanced_configuration
# .role_arn is required, and without it the service cannot be created at all.
#
# The AWS-managed policy, not a hand-written one, and this is the one place in
# the project where that is the *stricter* choice rather than the lazier one.
# The action set ECS uses mid-shift is not in the provider schema and cannot be
# read offline. A hand-rolled policy that is slightly too narrow does not fail
# at apply — it fails halfway through a production traffic shift, in the window
# where neither colour cleanly owns the listener. Plan §D5.
resource "aws_iam_role_policy_attachment" "bluegreen" {
  role       = aws_iam_role.bluegreen.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}
```

```hcl
# A separate role from bluegreen above, deliberately. deployment_configuration
# .lifecycle_hook.role_arn and load_balancer.advanced_configuration.role_arn are
# two required slots with two different permission sets — rewriting production
# routing, and invoking three functions. Design §8.1's stated premise is roles
# separated by function; merging these would give the rule-rewriter permission
# to invoke arbitrary Lambdas. Plan §D4.
#
# The resource list is the three hook ARNs, never a wildcard. This role is
# assumable by an AWS service on a trigger this account does not control the
# timing of, which is exactly when a wildcard stops being a convenience.
```

- [ ] **Step 3: Run the suite and commit**

Commit: `feat(infra): five production IAM roles, including the two the schema requires`.

---

### Task 5: The three hook functions

**Files:**
- Create: `infra/environments/prod/hooks.tf`
- Test: `infra/environments/prod/tests/bluegreen.tftest.hcl` (created here, extended in Task 8)

**Interfaces:**
- Consumes: `module.lambda`, `local.foundation.api_domain`, `var.hook_timeout_seconds`.
- Produces: `module.pre_scale_hook`, `module.post_test_hook`, `module.post_prod_hook`, each exposing `function_arn`.

- [ ] **Step 1: Write the failing assertions**

Create `tests/bluegreen.tftest.hcl` with the mock block, the remote-state overrides, and the hook assertions:

| Assertion | What it protects |
|---|---|
| Three functions exist, named `…-pre-scale-hook`, `…-post-test-hook`, `…-post-prod-hook` | The convention, and that the `hook_invoke` policy's three ARNs match three real functions |
| All three have `runtime = "python3.14"` and `architectures = ["arm64"]` | Phase 0 A4, and price parity with the Graviton container |
| `pre_scale_hook` and `post_prod_hook` probe `https://<api_domain>` | Both validate the production listener |
| `post_test_hook` probes `https://<api_domain>:8443` | **The dark canary's whole identity.** A hook that probes `:443` at `POST_TEST_TRAFFIC_SHIFT` validates the *old* colour and passes every bad build |
| No function has `BGD_EXPECT_DIGEST` in its environment | D12 — Terraform must never set it, or exit criterion 3's mechanism is not a deliberate act |
| Each `BGD_STAGE` matches the stage the service subscribes it to | Task 8 asserts the other half; together they stop a hook being wired to the wrong stage |
| All three timeouts are `var.hook_timeout_seconds` and it is ≥ 60 | Phase 5's F5 plus Task 2's arithmetic — three sequential probes are worst-case 50s, so a shorter function is killed mid-`/ready`, and D3 turns that into a rejection of a build that was fine |

Run and see them fail.

- [ ] **Step 2: Write `hooks.tf`**

Three `module "…"` blocks over `../../modules/lambda`, differing only in `function_name`, `environment` and the comment saying what the stage is for. The probe URLs are derived from `local.foundation.api_domain` rather than restated, so a domain change cannot leave a hook probing the wrong host.

The file's header comment carries D2's table — the three stages and what each rules out — because that is what someone reading `hooks.tf` needs and it is four screens away in the plan.

- [ ] **Step 3: Run the suite and commit**

Commit: `feat(infra): three blue/green lifecycle hook functions`.

---

### Task 6: The ALB, two target groups, three listeners, two rules

The largest single departure from staging's shape.

**Files:**
- Create: `infra/environments/prod/alb.tf`
- Test: `infra/environments/prod/tests/edge.tftest.hcl`

**Interfaces:**
- Produces: `aws_lb.this`, `aws_lb_target_group.blue`, `aws_lb_target_group.green`, `aws_lb_listener.{http,https,test}`, `aws_lb_listener_rule.{production,test}`.

- [ ] **Step 1: Write the failing assertions**

`tests/edge.tftest.hcl`. Staging's assertions carry over — the `/health` health check path, the 80→443 redirect, the foundation certificate, the TLS 1.3 policy, the 32-character names — plus:

| Assertion | What it protects |
|---|---|
| Two target groups, `…-api-blue` and `…-api-green`, identical but for name | An asymmetry between them means the two colours are not interchangeable, and blue/green stops being a swap |
| Both poll `/health`, never `/ready` | Staging's reason doubled: a DynamoDB hiccup deregistering every target in both groups at once |
| A `:8443` listener exists, on the foundation certificate | The test listener. Without it there is no dark canary and `test_listener_rule` has nothing to point at |
| `:443`'s rule forwards to blue; `:8443`'s rule forwards to green | The initial assignment. ECS swaps them from here |
| Both listeners' `default_action` is a fixed 503, not a forward | The rules carry `/*` so the default is unreachable in normal operation — which is exactly why it should be inert. A forwarding default silently keeps serving from a stale target group if a rule is ever deleted |
| Both rules have a priority and a `path_pattern` condition of `/*` | A rule without a condition is invalid; two rules without priorities collide |
| Only `:8443` and `:443` carry the certificate; `:80` does not | A certificate on the redirect listener is a sign someone made 80 serve traffic |

- [ ] **Step 2: Write `alb.tf`**

`staging/alb.tf` is the starting point. Its three checkov skips carry over, with **D7's reason rewritten in full for the access-logging skip** rather than pointing at staging (F7).

The listener shape:

```hcl
# Two listeners carry traffic and one redirects. The production listener is
# :443 and the test listener is :8443 — the port network's prod ALB security
# group already opens, and the reason that group differs from staging's.
#
# Both carry an aws_lb_listener_rule rather than relying on their default
# action, and that is not a style choice: advanced_configuration takes
# production_listener_rule and test_listener_rule, which are *rule* ARNs
# (Phase 0 A7). A default action cannot be named there, so a listener without a
# rule cannot participate in a blue/green shift at all.
#
# The default actions are therefore a fixed 503. Each rule matches /*, so the
# default is unreachable while the rules exist — which is precisely why it
# should refuse rather than forward. A forwarding default would keep serving
# from whichever target group it named if a rule were ever removed, and the
# colour it named would be the wrong one half the time.
```

- [ ] **Step 3: Run the suite and commit**

Commit: `feat(infra): production ALB with a test listener and two target groups`.

---

### Task 7: The four bake alarms

**Files:**
- Create: `infra/environments/prod/alarms.tf`
- Modify: `infra/environments/prod/tests/bluegreen.tftest.hcl`

**Interfaces:**
- Produces: `aws_cloudwatch_metric_alarm.five_xx`, `.p95_latency`, `.unhealthy["blue"]`, `.unhealthy["green"]`, and `local.bake_alarm_names`.

- [ ] **Step 1: Write the failing assertions**

| Assertion | What it protects |
|---|---|
| Exactly four alarms, with the convention's names | D8 |
| `five_xx` and `p95_latency` carry only the `LoadBalancer` dimension | Per-group scoping would trip on the old colour draining |
| `p95_latency` uses `extended_statistic = "p95"`, not `statistic = "Average"` | An average hides the tail the design named |
| Both `unhealthy` alarms carry `LoadBalancer` **and** `TargetGroup` | F3 — there is no LoadBalancer-only form |
| All four set `treat_missing_data = "notBreaching"` | The idle target group publishes nothing; the default parks the alarm in `INSUFFICIENT_DATA` |
| All four use `period = 60` and ≤ 2 evaluation periods | A five-minute bake cannot be gated by a five-minute alarm |
| No alarm has `alarm_actions` | D9 — Phase 9 owns notification, and a demo that emails on every run trains the recipient to ignore the topic |
| `local.bake_alarm_names` contains exactly those four names | Task 8 feeds this straight into `alarms.alarm_names`; a missing member is a silent gap in the gate |

- [ ] **Step 2: Write `alarms.tf`**

The two unhealthy-host alarms use `for_each` over the two target groups so they cannot drift apart. The file header records D8's dimension reasoning and states plainly that **the thresholds are chosen, not measured**, naming the runbook step that records the real numbers.

- [ ] **Step 3: Run the suite and commit**

Commit: `feat(infra): four bake-period alarms for automatic rollback`.

---

### Task 8: The blue/green ECS service — the centre of the phase

**Files:**
- Create: `infra/environments/prod/ecs.tf`
- Modify: `infra/environments/prod/tests/bluegreen.tftest.hcl`, `tests/compute.tftest.hcl`

**Interfaces:**
- Consumes: everything the previous five tasks produced.
- Produces: `aws_cloudwatch_log_group.api`, `aws_ecs_cluster.this`, `aws_ecs_task_definition.api`, `aws_ecs_service.api`.

- [ ] **Step 1: Write the failing assertions**

`compute.tftest.hcl` takes staging's assertions re-pointed at this layer — ARM64, `BGD_IMAGE_DIGEST` equal to the resolved digest, private subnets with no public IP, the prod security group, `propagate_tags`, the read-only root filesystem, the slash-separated log group name — with `desired_count == 2`.

`bluegreen.tftest.hcl` gains the assertions no other layer can make:

| Assertion | What it protects |
|---|---|
| `deployment_configuration.strategy == "BLUE_GREEN"` | The one word that is the entire difference from staging |
| `bake_time_in_minutes == "5"` — a **string** | F1. The number form fails validate; asserting the string keeps it that way |
| Exactly three `lifecycle_hook` members | A missing hook is a missing gate, and a `set` gives no ordering to notice it by |
| Each hook's `lifecycle_stages` is exactly `["PRE_SCALE_UP"]`, `["POST_TEST_TRAFFIC_SHIFT"]`, `["POST_PRODUCTION_TRAFFIC_SHIFT"]` — one stage each, matched to the function whose `BGD_STAGE` says the same | Task 5 asserted the function half. **This is the pairing assertion**, and a crossed wiring here means the dark canary runs against production and passes everything |
| Every hook's `role_arn` is `hook_invoke`, never `bluegreen` | D4 |
| `advanced_configuration.role_arn` is `bluegreen`, never `hook_invoke` | D4, the other direction |
| `advanced_configuration.production_listener_rule` and `test_listener_rule` are **rule** ARNs from Task 6 | Phase 0 A7. Passing a listener ARN fails at apply with a message that names the attribute, not the reason |
| One `load_balancer` block: `target_group_arn` is blue, `alternate_target_group_arn` is green | F1. Two `load_balancer` blocks is the shape people expect and the provider does not accept |
| `alarms.alarm_names == local.bake_alarm_names`, `enable == true`, `rollback == true` | The bake gate is wired to the four alarms Task 7 built, not to an empty set |
| `wait_for_steady_state == true` | D11 |
| No `deployment_circuit_breaker` block | See Step 2 |

- [ ] **Step 2: Write `ecs.tf`**

`staging/ecs.tf` is the base. The log group, cluster (with `containerInsights` explicitly disabled, Phase 5's D7, for the same Phase 9 reason) and task definition change only by prefix and `desired_count`.

The service is where it diverges:

```hcl
  # The whole phase, in one block. Staging writes ROLLING here.
  deployment_configuration {
    strategy             = "BLUE_GREEN"
    bake_time_in_minutes = tostring(var.bake_time_minutes) # string, not number — plan F1

    lifecycle_hook {
      hook_target_arn  = module.pre_scale_hook.function_arn
      role_arn         = aws_iam_role.hook_invoke.arn
      lifecycle_stages = ["PRE_SCALE_UP"]
    }
    # …POST_TEST_TRAFFIC_SHIFT and POST_PRODUCTION_TRAFFIC_SHIFT…
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = local.container_name
    container_port   = local.container_port

    advanced_configuration {
      alternate_target_group_arn = aws_lb_target_group.green.arn
      production_listener_rule   = aws_lb_listener_rule.production.arn
      test_listener_rule         = aws_lb_listener_rule.test.arn
      role_arn                   = aws_iam_role.bluegreen.arn
    }
  }

  alarms {
    alarm_names = local.bake_alarm_names
    enable      = true
    rollback    = true
  }
```

**No `deployment_circuit_breaker`.** Staging sets it, and this layer deliberately does not. The bake period with alarms *is* this environment's rollback mechanism, and whether the two interact — and in what order they would each try to revert — is not documented in the schema and not something to discover during a production shift. One rollback mechanism, chosen on purpose. The omission is asserted by a test so it reads as a decision rather than a gap, and the file comment says so.

`depends_on` covers both listeners, both listener rules, and both task-role policies — Phase 5's two reasons, plus the rules, which `advanced_configuration` references but which Terraform sequences no more reliably than it did the listener.

- [ ] **Step 3: Run the suite and commit**

Commit: `feat(infra): the ECS service with native blue/green, hooks, bake and alarms`.

---

### Task 9: DNS, outputs, and the full gate

**Files:**
- Create: `infra/environments/prod/dns.tf`, `outputs.tf`, `README.md`
- Test: `infra/environments/prod/tests/outputs.tftest.hcl`
- Modify: `makefile` — `TF_LAYERS` gains `prod`

**Interfaces:**
- Produces: `api_url`, `test_url`, `alb_dns_name`, `cluster_name`, `service_name`, `task_definition_family`, `image_digest`, `log_group_name`, `blue_target_group_arn`, `green_target_group_arn`, `hook_function_names`, `bake_alarm_names`, `accounts_table_name`, `transactions_table_name`.

- [ ] **Step 1: Write the failing output assertions**

`tests/outputs.tftest.hcl` pins every name, exactly as staging's does, so a rename fails here rather than three phases later as a null lookup. `test_url` is new and `scripts/smoke.sh` does not consume it — the runbook and Phase 11's evidence do.

`hook_function_names` and `bake_alarm_names` are outputs specifically so the runbook can tail the right log groups and read the right alarm states without deriving names by hand, and so Phase 9 attaches SNS actions to these alarms rather than creating parallel ones.

- [ ] **Step 2: Write `dns.tf` and `outputs.tf`**

`dns.tf` is staging's file with `api_domain` for `staging_api_domain`. Its comment about `evaluate_target_health` said "Phase 6 inherits the habit" — it now does, and here it is load-bearing rather than a good default: during a blue/green shift, health is the signal that a colour is serving.

- [ ] **Step 3: Add `prod` to `TF_LAYERS`**

`scripts/lint-infra.sh` already maps `prod` to `environments/prod` (its `layer_path` case covers `staging | prod`), and `scripts/tf.sh` and `scripts/teardown.sh` already know the layer. `TF_LAYERS := bootstrap foundation network staging prod` is the only makefile change, and `make teardown` stops printing "prod — no .tf files yet, skipping".

- [ ] **Step 4: Run the full gate**

```bash
make tf-check && make test-lambdas
```

Expect checkov findings on the Lambda functions (F7). **Do not skip them in bulk.** Each gets its own reason naming this function's actual risk profile: a synchronous deployment gate, invoked three times per deployment, holding no secrets, probing a public endpoint.

- [ ] **Step 5: Write `infra/environments/prod/README.md` and commit**

Commit: `feat(infra): production DNS, outputs, and the layer in the offline gate`.

---

### Task 10: The runbook

The handover document. Everything from here needs an AWS session, and none of it happens in this session (D1).

**Files:**
- Create: `docs/runbooks/phase-06-prod-blue-green.md`
- Modify: `docs/runbooks/README.md`

- [ ] **Step 1: Write it**

Following [the Phase 5 runbook](../../runbooks/phase-05-staging.md)'s shape, with the steps this phase needs:

1. **Preconditions** — `network` and `foundation` applied, `staging` green, the SNS subscription confirmed, an image in ECR.
2. **AWS session** — `aws sso login`, then `make verify-aws`.
3. **Confirm the managed policy exists** — `aws iam get-policy --policy-arn arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers`. **Before the apply, because D5's benign failure mode is only benign if it is caught early.** If the name is wrong, §6's fallback applies.
4. **Set `image_tag`** — from `cat app/dist/image-ref.txt`, or whatever is in ECR.
5. **Re-run the offline gate against the real toolchain** — `make tf-check`, `make test-lambdas`.
6. **Plan** — `make plan-prod`, and what to look for: five roles, four alarms, three functions, three listeners, two rules, two target groups.
7. **Apply** — `make apply-prod`. **Expect it to take several minutes and not return early** (D11). What a first apply looks like when there is no previous revision to shift from.
8. **Verify the exit-criteria baseline** — `make smoke-prod`, then `/health`, `/ready`, `/version` over TLS on `:443`, and `:8443` returning the same image while only one colour exists.
9. **Read the hook logs and record the real contract** — `aws logs tail` on the three hook log groups. **This is the step that retires F2.** Record what ECS did with the return value and what the event actually looked like, and amend the plan and handler if the contract turns out narrower than D3 assumed.
10. **Record the real alarm behaviour** — confirm all four leave `INSUFFICIENT_DATA` once traffic exists (F3), and record the observed 5xx count and p95 so D8's chosen thresholds can be replaced with measured ones.
11. **Build a second image** — a trivial `app/` change, `make build`, `make seed-ecr`. F5: two commits are required, and this must happen before step 12.
12. **Exit criterion 1 — a blue/green deployment completes.** Bump `image_tag`, `make apply-prod` in one terminal, `aws ecs list-service-deployments` and `describe-service-deployments` in another (D10).
13. **Exit criterion 2 — different SHAs on `:443` and `:8443`.** During the window between the test shift and the production shift, curl both ports. Exact commands, and the exact expected difference. **This is the direct proof of which colour serves whom**, and the window is minutes wide — the runbook says to have the commands ready before starting step 12.
14. **Exit criterion 3 — a deliberately failing hook aborts with zero traffic shifted.** `aws lambda update-function-configuration` setting `BGD_EXPECT_DIGEST` to a bogus value on the post-test hook, then a deploy. Confirm production never stopped serving the old digest, then **unset the variable** — with the warning that leaving it set breaks every subsequent deployment in a way that looks like a broken build.
15. **Teardown** — `make teardown` now destroys prod first. What survives, what does not.
16. **What goes wrong** — the failure table, including a stuck traffic shift, a hook timing out, an alarm in `INSUFFICIENT_DATA`, and a `wait_for_steady_state` timeout.

- [ ] **Step 2: Commit**

Commit: `docs: the Phase 6 runbook`.

---

### Task 11: Amendments and the local verification record

Every phase so far has amended the documents it contradicted rather than leaving them wrong. This phase contradicts four.

**Files:**
- Modify: `docs/2026-08-04-implementation-phase-roadmap.md`
- Modify: `docs/2026-08-04-blue-green-deployment-platform-design-research.md`
- Modify: `docs/naming-and-tagging-convention.md`
- Modify: `docs/phases/phase5/2026-08-28-phase-05-implementation-plan.md`
- Create: `docs/phases/phase6/2026-08-28-local-verification.md`

- [ ] **Step 1: Amend the roadmap**

In §3's Phase 6 section, in the style Phases 2 through 5 established:

- **The DynamoDB tables are missing from the task list** but present in §1's layer diagram. The layer builds them (D13).
- **`desired_count = 2`**, from design §10, which the task list does not state.
- **Design §8.1's six roles are seven** (D4), and this layer creates five of them.
- **Four decisions the task list does not name** — no circuit breaker, `wait_for_steady_state` (D11), no ALB access logs (D7), no `alarm_actions` (D9).
- **None of the three exit criteria is met by the branch alone.** The same note Phases 3, 4 and 5 carry.
- §2's branch table row 6 reads `feat/Phase6_ProdBlueGreen`, which is the branch used. **No amendment needed — say so**, as Phases 3 and 5 did.

- [ ] **Step 2: Amend the design research document**

- **§8.1** — its Phase 0 amendment added a sixth role. Add a seventh: `deployment_configuration.lifecycle_hook.role_arn` is a separately required slot with a different permission set (D4).
- **§7** — the hook table describes what each hook does but not what it returns. Add D3's contract and F2's caveat, since §7 is where someone looks for it.
- **§10** — production's Fargate share is two 0.25 vCPU / 0.5 GB **ARM64** tasks, which the table did not price, plus three Lambda functions invoked a handful of times per deployment, which the table does not list at all. Both are conservative rather than wrong; record the real figure from the runbook.

- [ ] **Step 3: Amend the naming and tagging convention**

- **§4's log group rule** gains its second deviation: Lambda log groups are `/aws/lambda/<function-name>` because that is what Lambda writes to unless redirected, and every console path assumes it (F8).
- **§6.3's timeline table** — mark the Phase 6 half of `propagate_tags` done, with the verification command.
- The **worked example at §7** lists production's resources. It predates this phase and does not include the hooks, the alarms, the test listener or the two extra roles. Bring it up to what the layer actually contains.

- [ ] **Step 4: Amend the Phase 5 plan**

Its D5 says "Phase 6 decides separately for production, where access logs are genuine blue/green evidence." That promise is now kept and the answer is no (D7). Add a one-line forward reference so a reader of the Phase 5 plan is not left waiting for a decision that has already been made elsewhere.

- [ ] **Step 5: Write the local verification record**

`docs/phases/phase6/2026-08-28-local-verification.md`, following [Phase 5's](../phase5/2026-08-28-local-verification.md):

1. **The gate** — full `make tf-check` and `make test-lambdas` output, and a table of every assertion in this layer with what it protects against.
2. **Static analysis triage** — checkov before and after, every skip and its reason, with the Lambda skips called out separately since they are new to this phase (F7). Note which of F7's predictions were wrong.
3. **The executed evidence** — the handler suite is the part of this phase that genuinely *runs* rather than being mocked, so it carries the weight Phase 5's smoke-script runs did. Include the `data.archive_file` output as proof the packaging works offline (F4), and note which mocks in Task 1 Step 2 turned out to be unnecessary.
4. **No AWS resource was created** — the same proof Phases 4 and 5 give.
5. **What remains before the exit criteria are met** — the runbook, enumerated, with F2 called out as the open question the runbook closes.
6. **Carried forward** — what Phases 7, 8, 9 and 11 inherit, especially `BGD_EXPECT_DIGEST` as Phase 8's per-deployment assertion (D12) and these four alarms as Phase 9's notification targets (D9).

- [ ] **Step 6: Run the full gate one last time**

```bash
make tf-check && make test-lambdas
```

Expected: all five layers pass, and the handler suite passes at ≥ 95% coverage.

- [ ] **Step 7: Commit**

Commit: `docs: Phase 6 amendments and the local verification record`.

- [ ] **Step 8: Open the pull request**

```bash
git push -u origin feat/Phase6_ProdBlueGreen
```

The description is §5 below, with each criterion marked as met by the branch or deferred to the runbook.

---

## 5. Exit criteria

The roadmap states three:

> A manual CLI blue/green deployment completes; `/version` returns different SHAs on `:443` and `:8443` mid-deployment, which is the direct proof of which colour serves whom; a deliberately failing hook aborts the deployment with zero production traffic shifted.

**None of the three is met by the branch alone.** All three need a running service, and this session creates nothing (D1). They are met when [the runbook](../../runbooks/phase-06-prod-blue-green.md) is executed — steps 12, 13 and 14 respectively.

The branch's own gate, all of it verifiable offline:

| # | Criterion | Verified by |
|---|---|---|
| 1 | `make tf-check` passes across all five layers | `make tf-check` |
| 2 | `make test-lambdas` passes at ≥ 95% coverage | `make test-lambdas` |
| 3 | The handler raises on failure rather than returning `FAILED` | `lambdas/tests/test_handler.py` — D3 |
| 4 | The handler ignores `BGD_EXPECT_DIGEST` when unset, and rejects on mismatch when set | `lambdas/tests/test_handler.py` — D12 |
| 5 | `strategy = "BLUE_GREEN"` and `bake_time_in_minutes` is the string `"5"` | `tests/bluegreen.tftest.hcl` |
| 6 | Exactly three lifecycle hooks, each on exactly one stage, each paired to the function whose `BGD_STAGE` agrees | `tests/bluegreen.tftest.hcl`, both the Task 5 function assertions and the Task 8 pairing assertions |
| 7 | The post-test hook probes `:8443`, not `:443` | `tests/bluegreen.tftest.hcl` |
| 8 | `advanced_configuration` carries two rule ARNs, the alternate target group, and the `bluegreen` role | `tests/bluegreen.tftest.hcl` |
| 9 | The hook-invoke role and the blue/green controller role are distinct, and each is used only in its own slot | `tests/data_and_iam.tftest.hcl`, `tests/bluegreen.tftest.hcl` |
| 10 | `alarms` is wired to exactly the four alarms, with `enable` and `rollback` true | `tests/bluegreen.tftest.hcl` |
| 11 | Four alarms with the right dimensions, 60-second periods, and `notBreaching` | `tests/bluegreen.tftest.hcl` |
| 12 | Two symmetric target groups, both polling `/health` | `tests/edge.tftest.hcl` |
| 13 | Both listeners carry a `/*` rule; both default actions are a fixed 503 | `tests/edge.tftest.hcl` |
| 14 | `runtime_platform` is ARM64, `BGD_IMAGE_DIGEST` equals the resolved digest, `desired_count` is 2 | `tests/compute.tftest.hcl` |
| 15 | `wait_for_steady_state` is true and no circuit breaker is set | `tests/bluegreen.tftest.hcl` |
| 16 | The tables match `app/src/bgd/repository/schema.py`, LSI included | `tests/data_and_iam.tftest.hcl` |
| 17 | The consumed output surface is present and correctly shaped | `tests/outputs.tftest.hcl` |
| 18 | checkov reports zero failures; every skip carries its own written reason | `./scripts/lint-infra.sh` |
| 19 | The deployment package builds offline from `handler.py` | `data.archive_file` executing during `terraform test` — F4 |

Criteria 2, 3, 4 and 19 are the ones executed against something real rather than mocked, which is why they are listed rather than folded into the gate.

---

## 6. Risks this phase adds

| Risk | Handling |
|---|---|
| **The hook response contract is unverified (F2)** | The largest open question in the phase. D3 makes the handler correct under either plausible contract, choosing the failure mode that rejects rather than promotes. The runbook's step 9 retires it against a real invocation. |
| **`AmazonECSInfrastructureRolePolicyForLoadBalancers` may not exist under that name** | Fails at apply with "policy does not exist", before creating anything. The runbook checks with `aws iam get-policy` first. **Fallback:** replace the attachment with an inline policy granting `elasticloadbalancing:Describe*`, `ModifyRule`, `ModifyListener`, `RegisterTargets` and `DeregisterTargets` on this ALB's listeners, rules and both target groups — and record it as a deviation, because D5's whole argument is that a hand-rolled list here is a guess. |
| **`wait_for_steady_state` turns a rolled-back deployment into a failed apply** | Intended (D11). A green plan over a reverted service is worse. The cost is a six-to-ten-minute apply, which Phase 7's pipeline inherits. |
| **A crossed hook wiring passes every bad build silently** | The single worst failure this layer can have: a `POST_TEST_TRAFFIC_SHIFT` hook probing `:443` validates the *old* colour and approves everything. Two assertions from opposite ends — the function's `BGD_PROBE_URL` and the service's `lifecycle_stages` pairing — are what catch it, which is why they are in different tasks. |
| **The alarm thresholds are chosen, not measured (D8)** | Stated as chosen everywhere they appear, including in `alarms.tf` itself. The runbook's step 10 records the real numbers. A threshold too tight rolls back a good deployment; too loose and the bake gates nothing. Both are visible from the first real deployment. |
| **`BGD_EXPECT_DIGEST` left set after the demonstration** | Breaks every subsequent deployment in a way that looks like a broken build. The runbook's step 14 ends by unsetting it and says this. Terraform never sets it, so a `terraform apply` does not silently fix it either — which argues for the runbook warning being prominent rather than a footnote. |
| **One rollback mechanism, not two** | The circuit breaker is deliberately omitted (Task 8). If the bake alarms prove insufficient in practice, adding it is a considered change with the interaction understood — not a default nobody chose. |
| **Six test files now repeat the same mock block** | Structural, as in Phase 5: Terraform's test framework has no shared-setup construct for `mock_provider`. `tests/mocks.tftest.hcl` is the reference copy; Task 9's interface test catches drift between copies. |
| **The `lambda` module has no tests of its own** | Deliberate (Task 3). It has no conditionals and no computed names; Task 5's assertions on three real instantiations cover everything it does. If Phase 9 adds branching for dependency-bearing packages, that phase adds the tests. |
| **`prod` depends on `foundation`'s state being readable to destroy** | Accepted, as in Phase 5. `foundation` is never destroyed — that is why it is a separate layer. |
