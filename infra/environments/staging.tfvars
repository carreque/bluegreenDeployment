# What makes an apply of infra/ the STAGING environment.
#
#   scripts/tf.sh plan staging      # passes this file and staging.backend.hcl
#
# Committed, unlike terraform.tfvars: nothing here is a secret, and the shape of
# an environment is source rather than local configuration. .gitignore carries an
# explicit exception for environments/*.tfvars for that reason.
#
# image_tag is deliberately absent. It changes with every build, it is the one
# input that decides what actually gets deployed, and a value committed here
# would go stale the moment anyone pushed an image. It arrives as -var from
# scripts/pipeline-deploy.sh, or from your own terraform.tfvars locally.

environment = "staging"

# No blue/green. Staging's job is to fail fast: one target group, a :443
# listener that forwards straight to it, a ROLLING deployment and a circuit
# breaker that reverts a task set which never stabilises.
enable_prod = false

# One task, deliberately: staging exists to fail fast, not to be available.
desired_count = 1

# Occasionally useful, all correct as they stand:
# task_cpu           = 256
# task_memory        = 512
# log_retention_days = 14
