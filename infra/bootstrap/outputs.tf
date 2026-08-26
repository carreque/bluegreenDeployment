output "state_bucket_name" {
  description = "Name of the state bucket. The literal every other layer's backend block repeats."
  value       = aws_s3_bucket.tfstate.bucket
}

output "state_bucket_arn" {
  description = "ARN of the state bucket, for the IAM policies later phases attach to the pipelines."
  value       = aws_s3_bucket.tfstate.arn
}
