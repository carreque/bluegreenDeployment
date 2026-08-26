# Phase 3 — Local Verification

**Date:** 2026-08-24
**Branch:** `feat/Phase3_BootstrapFoundation`
**Status:** Local gate green. **The phase's four exit criteria are not yet met** — see §5.
**Plan:** [Phase 3 implementation plan](./2026-08-24-phase-03-implementation-plan.md)
**Runbook:** [bootstrap and foundation applies](../../runbooks/phase-03-bootstrap-and-foundation.md)

Everything Phase 3 could build and prove without an AWS session was built and
proved. Nothing was applied. This document records what was run, what it
returned, and what is left.

**Headline:** two Terraform layers, nineteen plan-time assertions, zero AWS API
calls — and three defects found before any resource existed, one of them in a
file this phase did not write.

---

## 1. The gate

`make tf-check` runs `validate`, `tflint`, `checkov` and both test suites. None
of them needs credentials: `scripts/tf.sh` initialises with `-backend=false` for
those three commands, so the whole gate runs on a machine that has never logged
in.

```
$ make tf-check

==> terraform validate — bootstrap
Success! The configuration is valid.
==> terraform validate — foundation
Success! The configuration is valid.

==> tflint — bootstrap
  ✓ bootstrap clean
==> tflint — foundation
  ✓ foundation clean
==> checkov — infra/
Passed checks: 45, Failed checks: 0, Skipped checks: 12
  ✓ checkov clean
  ✓ static analysis passed

==> terraform test — bootstrap
Success! 5 passed, 0 failed.
==> terraform test — foundation
Success! 14 passed, 0 failed.

  all infra checks passed
```

### 1.1 The nineteen assertions

| Suite | Run | Asserts |
|---|---|---|
| `bootstrap/state_bucket` | `bucket_name_follows_the_naming_convention` | the globally-unique, immutable name |
| | `versioning_is_enabled` | the only recovery path for corrupted state |
| | `encryption_is_server_side_and_free` | AES256, not KMS (D4) |
| | `the_bucket_is_closed_to_the_public_four_ways` | all four flags, not three |
| | `old_state_versions_expire_but_not_immediately` | 90-day noncurrent expiry |
| `foundation/naming_and_tags` | `the_four_tag_keys_are_spelled_exactly…` | exact keys, no extras, no omissions |
| | `shared_layers_tag_themselves_shared` | `environment = shared` |
| | `the_name_prefix_leaves_room_for_the_longest_alb_name` | the 32-character ALB cap |
| | `both_api_domains_derive_from_one_variable` | both hostnames from `domain_name` |
| `foundation/zone_and_certificate` | `adopts_the_zone_the_registrar_created` | the adopt path, against a mocked existing zone |
| | `creates_a_zone_when_the_account_has_none` | the create path, against an empty account |
| | `the_certificate_covers_both_environments` | primary name, SAN, DNS validation |
| | `one_validation_record_per_name` | two validation records |
| `foundation/registry_and_artifacts` | `the_registry_name_matches_the_image_phase_2_builds` | the seed is a push, not a retag |
| | `tags_in_the_registry_are_immutable_and_scanned` | `IMMUTABLE` + scan on push |
| | `the_registry_does_not_grow_without_bound` | two lifecycle rules, count of 10 |
| | `the_artifact_bucket_is_versioned_and_private` | name, versioning, four access flags |
| | `alerts_go_to_a_named_topic_by_email` | topic name, protocol, endpoint |
| | `the_github_connection_is_a_github_connection` | provider type, 32-character cap |

Both zone paths are covered. The create path is the one nobody will exercise
before needing it to work, which is precisely why it is tested.

---

## 2. Static analysis triage

`checkov` reported **12 findings**, all of them correct for a generic AWS
account and none of them correct here. Each is suppressed by an inline
`# checkov:skip=<ID>:<reason>` **inside** the resource block, with a reason that
names the decision it defends.

| ID | Resource(s) | Outcome | Reason |
|---|---|---|---|
| `CKV_AWS_145` | both S3 buckets | Skip | SSE-S3 is deliberate (D4). Every state read and write across five layers would be a billed KMS request on a bucket already private to one account. |
| `CKV_AWS_136` | `aws_ecr_repository.api` | Skip | Same decision. Every ECS task start pulls layers from here; KMS bills a decrypt per layer per task. |
| `CKV_AWS_26` | `aws_sns_topic.alerts` | Skip | The AWS-managed key's policy cannot be edited to let CloudWatch publish, which would silently disable Phase 6's rollback alarms and Phase 9's alerts (D5). |
| `CKV_AWS_144` | both S3 buckets | Skip | Single-region project by design (design §5). The disaster model is "rebuild from code". |
| `CKV_AWS_18` | both S3 buckets | Skip | Access logging needs a target bucket that needs a target bucket. CloudTrail already records configuration changes. **Object-level reads are genuinely not logged** — accepted, not argued away. |
| `CKV2_AWS_62` | both S3 buckets | Skip | Nothing subscribes to S3 events. A notification with no consumer is configuration that does nothing but appear to. |
| `CKV2_AWS_39` | `aws_route53_zone.this` | Skip | Query logging bills CloudWatch ingestion per DNS lookup for a project with no traffic analysis to do. |
| `CKV2_AWS_38` | `aws_route53_zone.this` | Skip | DNSSEC is a deliberate deferral: an asymmetric KMS key with a monthly charge, a DS record lodged manually at the registrar — a fourth manual step — and a misconfiguration takes the domain offline rather than degrading. |

Two honest notes on this table.

**The `CKV_AWS_18` skip concedes something.** S3 server access logging is the
only thing that records object-level reads, and CloudTrail management events do
not substitute for it. The reason given is a trade-off, not a refutation.

**The two Route 53 findings are against a resource that will not exist.**
`aws_route53_zone.this` has `count = 0` on the adopt path, which Phase 0 proved
is the path this account takes. checkov analyses the configuration, not the
plan, so it flags the block regardless. The skips are still worth writing,
because the create path is real code that a fresh account would execute.

`tflint` 0.60.0 with AWS ruleset 0.44.0 reported **no findings** on either layer.

---

## 3. Defects found before the first apply

### F4 — Design §1.7's find-or-create snippet aborts on a null

Recorded in full in the plan. The published filter `!z.private_zone` fails with
`argument must not be null`. Corrected to `z.private_zone != true`, which is
null-safe and identical for every non-null value. **This is the case for writing
the test first**: the expression looks correct, `terraform validate` accepts it,
and the failure would have surfaced as a plan error against a real account with
zones this project does not own.

[Design §1.7 amended.](../../2026-08-04-blue-green-deployment-platform-design-research.md)

### F7 — `make` gave an unrelated AWS account precedence over the project's

Found while capturing evidence for this document. The shell in which Phase 3 was
worked exports `AWS_PROFILE=rose-non-prod`, a live session on a **different
account entirely**:

```
$ make verify-aws
==> AWS session
  profile: rose-non-prod
  account    053530957204     ✗ expected 590184028094
  arn:       arn:aws:sts::053530957204:assumed-role/AWSReservedSSO_UserFull_…
```

The makefile has read `AWS_PROFILE ?= bootcamp-administrator-access` since Phase
0. **GNU Make gives an environment variable precedence over `?=`**, so the
project's default never applied:

```
$ A=from-environment make -f probe.mk    # A ?= makefile-default
?= gives: from-environment
$ B=from-environment make -f probe.mk    # B := makefile-default
:= gives: makefile-default
$ B=from-environment make -f probe.mk B=from-command-line
:= gives: from-command-line
```

This was harmless through Phase 2, because no `make` target reached AWS. **It
stops being harmless with `apply-%`, which Phase 3 adds**: `make apply-foundation`
in this shell would have run Terraform against a corporate account.

Two independent fixes, both kept:

1. `AWS_PROFILE`, `AWS_REGION` and `AWS_ACCOUNT_ID` changed from `?=` to `:=`.
   A `:=` assignment overrides the environment while still yielding to an
   explicit `make AWS_PROFILE=other <target>`, which is the only override that
   should count.
2. **`allowed_account_ids = [var.account_id]` on both layers' providers**, which
   was already written before this was found. It is a plan-time hard stop, and it
   is what would have caught the mistake even with the makefile unfixed. This
   finding is the argument for keeping it.

### F-shell — `die()` wrote to stdout, so a helper that died inside `$(...)` was silent

**Fixed at the root, not worked around.** `lib/common.sh` now writes `warn`,
`fail` and `die` to **stderr**, with a second colour palette keyed on `-t 2` so
`script > log` keeps colour on the errors still reaching the terminal.
`mark_ok`/`mark_fail`/`mark_warn` deliberately stay on stdout — they are the last
column of a table row printed there, and splitting one row across two streams
scrambles it under redirection.

Before and after, on the shape that first exposed it:

```
$ ./scripts/tf.sh test nosuchlayer          # before
$ echo $?
1                                            # no message on any stream

$ ./scripts/tf.sh test nosuchlayer >out 2>err   # after
$ echo $?; cat out; cat err
1
                                             # stdout clean
  ✗ unknown layer: nosuchlayer (expected bootstrap, foundation, network, staging or prod)
```

Verified against a helper that dies inside a substitution — the case that was
previously silent now reports and exits 1. Checked first that nothing in
`scripts/` captures the stdout of `fail`/`die`/`warn`, and that
`verify-tools.sh`'s table alignment survives the split. Both hold.

---

## 3.1 Second-pass audit of the Phase 3 scripts

Run after the fixes above, against the three scripts this phase created. Two
real defects, both found by measurement rather than reading.

### F8 — `docker run --env NAME=value` leaks the ECR token into `ps`

`seed-ecr.sh` passed the registry token as `--env "DEST_PASSWORD=$password"`,
under a comment claiming this kept it out of the host's process list. **The
comment was wrong.** `--env NAME=value` is a docker CLI *argument*, and argv is
exactly what `ps` prints:

```
$ docker run --rm --env "P=$SECRET" alpine sleep 8 &
$ ps -Ao args | grep -c -f secret.txt
1

$ export P="$SECRET"; docker run --rm --env P alpine sleep 8 &
$ ps -Ao args | grep -c -f secret.txt
0
```

The window is the whole duration of the image push, not an instant, and an ECR
token is a live twelve-hour credential for the registry every later phase
deploys from. Fixed to the name-only form, with the value exported into the
script's own environment and `unset` afterwards.

The measurement needed two attempts: the first run put the secret in the probe
command itself so `ps` matched my own shell, and the second used `docker run -d`,
which returns immediately so the CLI process was already gone. Both are recorded
because either one alone would have produced a confident wrong answer.

### F9 — the lint script duplicated the makefile's layer list

`lint-infra.sh` hard-coded `LAYERS=(bootstrap foundation)` while the makefile
held `TF_LAYERS`. Adding `network` in Phase 4 would need both edited, and the
failure mode of forgetting is a layer that is **silently never scanned** — the
run still reports clean. Fixed: the makefile passes `$(TF_LAYERS)`, and with no
arguments the script discovers layers from directories containing `.tf` files,
excluding `.terraform/`. Verified both paths produce `bootstrap` and
`foundation`.

### Checked and found sound

| Check | Result |
|---|---|
| Is tflint actually linting, or passing on zero files? | **Linting.** A deliberately unused variable was caught: `terraform_unused_declarations` at `bootstrap/main.tf:129`. A linter that silently scans nothing reports clean, so this was measured rather than assumed. |
| Does `quay.io/skopeo/stable` have `sh` and `skopeo` for the `--entrypoint` override? | Yes — `/usr/bin/skopeo`, version 1.20.0. |
| Does `terraform init -backend=false` break a layer already initialised against a real backend, and vice versa? | No. Full round trip — backend init → apply → `-backend=false` → validate → test → backend init → plan — is clean in both directions with no `-reconfigure`. **Tested with a `local` backend**; the S3 case cannot be tested without credentials, so if the runbook hits a backend complaint, `terraform init -reconfigure` is the fix. |
| Does `set -e` abort on `[[ … ]] && warn` in `build-image.sh`? | No. The AND-list's failure is not fatal; the next line runs. |
| Do the new array shapes work on **bash 3.2**, which macOS ships? | Yes. `${#A[@]}` on an empty array under `set -u` is safe there (it is `"${A[@]}"` that is not), and the `while read` + process-substitution discovery loop returns both layers. |

One further change came out of the audit rather than a defect: `tf.sh` no longer
runs `init` before `fmt`. Formatting parses HCL and touches no provider, backend
or state, and requiring a successful `init` first would make it fail on a layer
whose providers cannot be downloaded — the moment formatting is most likely to
be wanted.

---

## 4. No AWS resource was created

The evidence is that there is no session capable of creating one:

```
$ make verify-aws
==> AWS session
  profile: bootcamp-administrator-access
  ✗ no usable session on profile 'bootcamp-administrator-access'
aws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed
```

Every command in §1 initialises with `-backend=false` and plans against
`mock_provider`. No `terraform plan`, `apply` or `destroy` against a real
provider was run, and `scripts/seed-ecr.sh` was exercised only as far as its
local guards:

```
$ ./scripts/seed-ecr.sh
  ✗ refusing to seed a dirty build (0.1.0-84d4eb0-dirty) — commit the tree and rebuild
```

It stops on a local precondition before reaching any AWS call — which is both the
intended behaviour and the only verification of it available in this session.

---

## 5. What remains before Phase 3's exit criteria are met

All four are met by executing
[the runbook](../../runbooks/phase-03-bootstrap-and-foundation.md), which needs
an AWS session this machine does not currently have.

- [ ] `aws sso login --profile bootcamp-administrator-access`
- [ ] `make apply-bootstrap` — **state backend live and locking**
- [ ] `make apply-foundation` — **certificate issued and validated**; confirm the
      plan shows the zone **adopted**, with no `aws_route53_zone.this`
- [ ] Authorise the CodeConnections link in the console → `AVAILABLE`
- [ ] Confirm the SNS email subscription → an ARN, not `PendingConfirmation`
- [ ] Activate the four cost allocation tag keys under Billing — **the one with a
      deadline**, because activation is not retroactive
- [ ] `make build && make seed-ecr` on a clean tree — **ECR holds the seeded
      image**, digest verified against `app/dist/image-digest.txt`

Until then the branch's gate is `make tf-check`, and it is green.

---

## 6. Carried forward

| Item | Why it matters |
|---|---|
| **The domain expires 2026-12-18, auto-renew off** | Under four months away, and the certificate issued by this phase depends on it. Every environment's TLS and DNS depends on it from Phase 5. Not something the IaC can fix. |
| **The shell's ambient `AWS_PROFILE`** | F7's makefile fix covers `make`. A bare `terraform -chdir=… apply` typed by hand does not go through `make`, and `allowed_account_ids` is the only thing that stops it. |
| **`bootstrap`'s state is local and not in git** | By design. Recovery is one `terraform import`, and the command is in `infra/bootstrap/README.md`. |
| **The backend block's literal bucket name** | A backend block cannot interpolate, so nothing mechanical keeps it and `var.account_id`'s default in agreement. |
