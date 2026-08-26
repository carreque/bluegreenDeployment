# The registry Phase 3 seeds and Phase 8 pushes to.
#
# The repository name is deliberately identical to the image name
# scripts/build-image.sh produces (Phase 2 §D5), so seeding is a push of the
# artifact of record rather than a retag of a copy.

resource "aws_ecr_repository" "api" {
  # checkov:skip=CKV_AWS_136:AES256 rather than KMS, for the reason recorded in the Phase 3 plan §D4. Every ECS task start pulls layers from here; KMS would bill a decrypt request per layer per task.
  name = "${local.name_prefix}-api"

  # A mutable tag can be moved to different bytes later. Every deployment record,
  # every /version response and every rollback in Phase 11 would then name a tag
  # that no longer identifies what actually ran.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  # Order matters: rules are evaluated by ascending priority and an image is
  # acted on by the first rule that selects it. Untagged images are cleared
  # first so they do not occupy slots in the count-based rule below.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after one day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retain the ${var.ecr_max_image_count} most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_max_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
