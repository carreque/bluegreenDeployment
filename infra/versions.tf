terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }

    # Required by ../modules/lambda, which hooks.tf instantiates three times
    # when enable_prod is true. The module zips handler.py with
    # data.archive_file, and mock_provider "aws" does not touch a different
    # provider — so the archive is really built during terraform test, which is
    # what proves the packaging works offline rather than mocking it away.
    # Phase 6 plan §F4.
    #
    # Declared unconditionally even though only the production instantiation
    # uses it. required_providers is not conditional, and a provider declared
    # but unused costs a download and nothing else.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # PARTIAL, unlike the three layers before it, and this is the one structural
  # cost of merging staging and prod into a single root module.
  #
  # A backend block cannot interpolate, and this root is applied twice — once
  # per environment, into two different state keys. The bucket and key
  # therefore move out to environments/<env>.backend.hcl and arrive as
  # `terraform init -backend-config=...`. bootstrap, foundation and network
  # keep their literal blocks: they are applied once each and have nothing to
  # parameterise.
  #
  # What a literal block bought was that the state key could not be mismatched
  # with the configuration. That guarantee is now scripts/tf.sh's: it derives
  # the backend file AND the var file from one layer-name argument, and re-runs
  # init with -reconfigure on every invocation, so the pair cannot come apart
  # for any caller going through `make`. A bare `terraform -chdir=infra apply`
  # is the shape that can still get it wrong, which is why the runbooks now
  # spell out both flags rather than either alone.
  backend "s3" {}
}
