# The shape is fixed by app/src/bgd/repository/schema.py, which calls itself the
# single source of truth and is read by the application, the local bootstrap and
# the tests. This file is the Terraform restatement of it, and the tests in
# tests/data_and_iam.tftest.hcl assert the two agree.
#
# On-demand billing rather than provisioned: an idle staging environment then
# costs nothing at all, which is what makes leaving it up between sessions a
# decision about the ALB and NAT rather than about the tables.

resource "aws_dynamodb_table" "accounts" {
  # checkov:skip=CKV_AWS_28:point-in-time recovery buys nothing on tables that make teardown destroys and rebuild recreates empty. There is no point in time worth recovering to. Plan §D6.
  # checkov:skip=CKV_AWS_119:the AWS-owned key, for the reason recorded in the Phase 3 plan §D4. A customer-managed CMK bills a request per read and per write on the application's entire data path.
  name         = "${local.env_prefix}-accounts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "account_id"

  # Explicit rather than relying on the provider's own default: left unset,
  # this Optional-but-not-Computed argument plans as null rather than false,
  # which is indistinguishable from "unknown" to a test asserting on it and
  # would make `terraform destroy` fail unpredictably if AWS ever changed its
  # side of the default. tests/data_and_iam.tftest.hcl asserts it is false.
  deletion_protection_enabled = false

  attribute {
    name = "account_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "transactions" {
  # checkov:skip=CKV_AWS_28:as above — plan §D6.
  # checkov:skip=CKV_AWS_119:as above — Phase 3 plan §D4.
  name         = "${local.env_prefix}-transactions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "account_id"
  range_key    = "transaction_id"

  # As on accounts, above: explicit so the plan value is a known false rather
  # than null.
  deletion_protection_enabled = false

  # transaction_id is derived from the idempotency key, so this sort key IS the
  # idempotency guard — the application writes with attribute_not_exists and
  # needs no separate guard item. See schema.py's module docstring.
  attribute {
    name = "account_id"
    type = "S"
  }

  attribute {
    name = "transaction_id"
    type = "S"
  }

  # Declared because the LSI sorts on it. DynamoDB requires an attribute
  # definition for every key of every index, and only for those.
  attribute {
    name = "created_at"
    type = "S"
  }

  # An LSI can only be created with its table. Getting this wrong is not a fix
  # in a later phase — it is destroying the table and losing whatever is in it.
  local_secondary_index {
    name            = "created_at-index"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled = true
  }
}
