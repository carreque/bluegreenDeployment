output "name_prefix" {
  description = "The <project>-<region> prefix every resource name in every layer starts with."
  value       = local.name_prefix
}

output "common_tags" {
  description = "The four convention tags. Later layers read this so a tag key can only be spelled once."
  value       = local.common_tags
}

output "api_domain" {
  description = "Production API hostname."
  value       = local.api_domain
}

output "staging_api_domain" {
  description = "Staging API hostname."
  value       = local.staging_api_domain
}

output "zone_id" {
  description = "Hosted zone id, whether adopted or created. Phases 5 and 6 write their A records into it."
  value       = local.zone_id
}

output "zone_was_created" {
  description = "False when the registrar's zone was adopted. True means the registrar's name servers still need repointing."
  value       = !local.zone_exists
}

output "certificate_arn" {
  description = "ARN of the ACM certificate both environments' HTTPS listeners reference."
  value       = aws_acm_certificate.api.arn
}

output "ecr_repository_url" {
  description = "Registry URL the ECS task definitions pull from and the seed script pushes to."
  value       = aws_ecr_repository.api.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the registry, for the task execution role's pull policy in Phases 5 and 6."
  value       = aws_ecr_repository.api.arn
}

output "artifact_bucket_name" {
  description = "Versioned bucket for build outputs, test reports and SBOMs."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifact_bucket_arn" {
  description = "ARN of the artifact bucket, for the CodeBuild role's write policy in Phase 8."
  value       = aws_s3_bucket.artifacts.arn
}

output "alerts_topic_arn" {
  description = "Topic every alarm and pipeline failure notification publishes to."
  value       = aws_sns_topic.alerts.arn
}

output "github_connection_arn" {
  description = "CodeConnections ARN. Both pipelines source through it; unusable until authorised in the console."
  value       = aws_codeconnections_connection.github.arn
}

output "infra_pipeline_name" {
  description = "Name of the infrastructure pipeline. Phase 9's EventBridge rule filters execution state changes on it."
  value       = aws_codepipeline.infra.name
}

output "infra_pipeline_arn" {
  description = "ARN of the infrastructure pipeline."
  value       = aws_codepipeline.infra.arn
}

output "infra_apply_role_arn" {
  description = "The role the pipeline's applies run as. Recorded because 'who changed this' is the first question about any resource this project creates."
  value       = aws_iam_role.infra_apply.arn
}

output "image_tag_parameter_names" {
  description = "SSM parameters holding the tag each environment deploys, keyed by environment. Phase 8 writes these after pushing an image; scripts/pipeline-terraform.sh reads them."
  value       = { for env, p in aws_ssm_parameter.image_tag : env => p.name }
}
