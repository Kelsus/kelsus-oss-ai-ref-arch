output "audit_bucket" {
  description = "S3 bucket holding CloudTrail + Config deliveries, or null when neither is enabled."
  value       = local.create_bucket ? aws_s3_bucket.audit[0].id : null
}

output "cloudtrail_arn" {
  description = "ARN of the per-account CloudTrail, or null when an org trail covers it."
  value       = var.enable_cloudtrail ? aws_cloudtrail.main[0].arn : null
}

output "cloudtrail_log_group" {
  description = "CloudWatch Logs group mirroring CloudTrail, or null when disabled."
  value       = var.enable_cloudtrail ? aws_cloudwatch_log_group.trail[0].name : null
}

output "guardduty_detector_id" {
  description = "GuardDuty detector id, or null when disabled."
  value       = var.enable_guardduty ? aws_guardduty_detector.this[0].id : null
}
