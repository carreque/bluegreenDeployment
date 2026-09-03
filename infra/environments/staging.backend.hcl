# Backend for the staging apply. Passed as `terraform init -backend-config=...`
# because versions.tf's backend block is partial — see the comment there.
#
# The bucket is bootstrap's, and the key matches the layer name scripts/tf.sh,
# teardown.sh and rebuild.sh use. Changing the key here silently starts a NEW
# empty state rather than failing, so it is the one line in this file worth
# reading twice.
bucket       = "bgd-us-east-1-tfstate-590184028094"
key          = "staging/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
