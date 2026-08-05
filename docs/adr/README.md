# docs/adr — Phase 11

Architecture Decision Records for the deviations significant enough to need
defending to someone arriving cold.

Planned:

1. **ECS-native blue/green over CodeDeploy** — a deliberate deviation from the
   brief's named service list, justified by AWS's own March 2026 guidance.
2. **One NAT Gateway over VPC interface endpoints** — the intuitive cost answer is
   wrong at two AZs.
3. **Five Terraform layers over four** — splitting platform into `foundation` and
   `network` is what makes destroy-when-idle possible.

One decision per file, named `NNNN-short-title.md`, each recording context,
the decision, and consequences including the ones we would rather not have.
