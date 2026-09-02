# What makes an apply of infra/ the PRODUCTION environment.
#
#   scripts/tf.sh plan prod         # passes this file and prod.backend.hcl
#
# Committed, unlike terraform.tfvars: nothing here is a secret, and the shape of
# an environment is source rather than local configuration. .gitignore carries an
# explicit exception for environments/*.tfvars for that reason.
#
# image_tag is deliberately absent — see staging.tfvars for why. On THIS
# environment, supplying a new one is not a config edit: it is what starts a
# blue/green deployment. `make apply-prod` registers a new task definition
# revision, ECS provisions green, runs the three hooks, shifts traffic and bakes
# for five minutes under the alarms. The apply does not return until that has
# finished or rolled back (wait_for_steady_state), so expect six to ten minutes.
# See docs/runbooks/phase-06-prod-blue-green.md.

environment = "prod"

# The blue/green machinery: the green target group, the :8443 test listener, the
# two listener rules ECS rewrites mid-shift, the BLUE_GREEN strategy with its
# three lifecycle hooks, the bluegreen and hook_invoke roles, the three hook
# Lambdas, and the four bake alarms. variables.tf lists exactly what it gates.
enable_prod = true

# Two, not staging's one, for two independent reasons: design §10 prices
# production at two tasks, and two tasks across two availability zones is the
# minimum that makes the UnHealthyHostCount bake alarm mean "one task is sick"
# rather than being a synonym for "the service is down".
desired_count = 2

# Occasionally useful, all correct as they stand:
# task_cpu             = 256
# task_memory          = 512
# log_retention_days   = 14
# bake_time_minutes    = 5
# hook_timeout_seconds = 90
# alarm_p95_seconds    = 2
