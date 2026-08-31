# Phase 3 — the hosted zone was never adopted

**Date:** 2026-08-31
**Found:** during the first real execution of
[the Phase 3 runbook](../../runbooks/phase-03-bootstrap-and-foundation.md), at step 3
**Fixed by:** `fix/route_53_records`, merged as PR #12
**Files:** `infra/foundation/route53.tf`,
`infra/foundation/tests/zone_and_certificate.tftest.hcl`

`make apply-foundation` blocked on `aws_acm_certificate_validation.api[0]` for
39 minutes and would have blocked for 75 before failing. The find-or-create of
design §1.7 had taken the **create** path on an account that already held a
correctly delegated hosted zone — the exact outcome Phase 0's A3 finding
recorded as impossible here.

---

## 1. Symptom

```
aws_acm_certificate_validation.api[0]: Still creating... [39m10s elapsed]
```

Not slow. Stuck, and it would have stayed stuck until the resource's 75-minute
default timeout.

## 2. What was actually in the account

Two hosted zones for one domain:

```
Z01311493LQ7UOIRHM1H9   carloscloudengineer.com.   RISWorkflow-RD:…        (registrar)
Z01612752Q1RC1FX16GK6   carloscloudengineer.com.   terraform-v3x0s8L8A9…   (this apply)
```

The registrar delegates to the **first**:

| Source | Name servers |
|---|---|
| `route53domains get-domain-detail` | `ns-1470.awsdns-55.org`, `ns-1787.awsdns-31.co.uk`, `ns-450.awsdns-56.com`, `ns-930.awsdns-52.net` |
| `Z01311493LQ7UOIRHM1H9` | identical |
| `Z01612752Q1RC1FX16GK6` | `ns-753.awsdns-30.net`, `ns-1089.awsdns-08.org`, `ns-200.awsdns-25.com`, `ns-1997.awsdns-57.co.uk` |

Both ACM validation CNAMEs had been written into the Terraform zone, which is
authoritative for nobody:

```
Z01612752…   CNAME  _30052a5b….api.carloscloudengineer.com.
Z01612752…   CNAME  _db1239ea….staging-api.carloscloudengineer.com.
Z01311493…   (NS and SOA only)
```

So ACM was polling public DNS for records that public DNS could not serve. The
certificate sat `PENDING_VALIDATION` and nothing was ever going to change that.

## 3. Root cause

`route53.tf`'s matcher compared the provider's zone name against the domain
**with a trailing dot**:

```hcl
if zone.name == "${var.domain_name}." && zone.private_zone != true
```

The Route 53 *API* renders a zone name as `carloscloudengineer.com.`, which is
where that spelling came from. The *provider* does not: `aws_route53_zone`
normalises it. Probed directly against provider 6.61.0 rather than assumed:

```
names_exactly_as_the_provider_returns_them = {
  "Z01311493LQ7UOIRHM1H9" = "carloscloudengineer.com"
  "Z01612752Q1RC1FX16GK6" = "carloscloudengineer.com"
}
matches_the_filter_in_route53_tf = []
would_match_without_trailing_dot  = ["Z01311493LQ7UOIRHM1H9", "Z01612752Q1RC1FX16GK6"]
```

`matched_zone_ids` was therefore **always empty**, `zone_exists` **always
false**, and `aws_route53_zone.this` created unconditionally. Not a
race, not an ordering problem, not account state: the adopt path was
unreachable from the day it was written.

## 4. Why the gate did not catch it

`tests/zone_and_certificate.tftest.hcl` mocked the data source with

```hcl
name = "carloscloudengineer.com."
```

— the API's spelling, not the provider's. `run "adopts_the_zone_the_registrar_created"`
passed against a value the provider never produces. **`make tf-check` was green
for every one of the four phases that ran it**, and the assertion it was green
on was tautological.

This is the sharper half of the finding. A mock is evidence exactly to the
extent that it matches the thing it replaces, and nothing in the offline gate
can tell you when it stops doing so. The defect was not in the assertion, the
resource, or the reviewer — it was in a fixture nobody had reason to re-read.

## 5. The fix

```hcl
if trimsuffix(zone.name, ".") == trimsuffix(var.domain_name, ".") && zone.private_zone != true
```

Both sides trimmed rather than the literal's dot dropped, so a provider that
normalises the other way in some future version does not reintroduce the bug
from the opposite direction.

The mock is corrected to the undotted form, **and** a second mock provider
`zone_present_dotted` asserts the dotted spelling adopts too. Neither run alone
is sufficient: the first is the truth today, the second is the truth the
provider could return tomorrow.

Verified, rather than asserted:

- `terraform test` on `foundation` — **77 passed, 0 failed**
- with the old matcher restored and the corrected mock in place, the adopt run
  **fails** — so the test now catches the defect it was supposed to catch

## 6. Recovery

The certificate was **not** recreated. Validation CNAMEs are a property of the
certificate, not of the zone, so once the records existed in the delegated zone
ACM issued the certificate it already had. Recovery was:

1. `Ctrl-C` the apply — `aws_acm_certificate_validation` creates nothing in AWS,
   so cancelling it costs nothing.
2. Merge the fix, making the registrar zone the only match.
3. `make plan-foundation` — `aws_route53_zone.this[0]` destroyed, both validation
   records replaced into `Z01311493LQ7UOIRHM1H9`, certificate untouched.
4. `make apply-foundation`.

## 7. What this changes elsewhere

**Phase 0's A3 finding was correct and is not amended.** The zone existed, was
delegated, and resolved publicly — all three checks were right. What A3 could
not know is whether the code was able to act on the answer. That gap is worth
naming: a verification phase can establish a fact about the world and still
leave the code that consumes it untested against reality.

**The risk A3 retired was retired one step too early.** Design §11's *"ACM
validation hangs on the zone-create path"* and roadmap §4's equivalent row were
both marked retired on the strength of the adopt path being taken. The adopt
path was never taken. The risk did not merely remain open — it fired, on the
first apply, exactly as written.

**The two-phase `wait_for_validation = false` escape hatch earned its place.**
It was written for a create path that Phase 0 concluded would never happen, and
it is the reason the failure was recoverable without abandoning the apply.
