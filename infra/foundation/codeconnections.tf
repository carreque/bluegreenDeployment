# The link CodePipeline uses to read carreque/bluegreenDeployment.
#
# Created here rather than in Phase 7 because it is the one resource in the
# project that a human must finish. Terraform creates it PENDING; authorising it
# is a click in the console, and until that happens every pipeline sourcing from
# it fails. Creating it three phases early turns a blocking step into a
# background one.
#
# aws_codeconnections_connection, not aws_codestarconnections_connection: the
# service was renamed and the provider keeps the old spelling only for
# compatibility (Phase 3 plan §F1).
resource "aws_codeconnections_connection" "github" {
  name          = "${local.name_prefix}-github"
  provider_type = "GitHub"
}
