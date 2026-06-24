variable "name_prefix" {
  description = "Prefix for resource names (typically the org/account short name)."
  type        = string
}

variable "env" {
  description = "Scope label for names/tags (e.g. \"account\")."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. SOC2 expects audit logs kept >= 1 year."
  type        = number
  default     = 365
}

# Per-service toggles. All cost money continuously; leave on for the account that
# is actually under audit, flip off for throwaway experiment accounts.
variable "enable_cloudtrail" {
  description = "Create a per-account CloudTrail. Set false when an org-wide trail already covers this account (the usual case in an AWS Organization)."
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Enable GuardDuty threat detection (CC7)."
  type        = bool
  default     = true
}

variable "enable_config" {
  description = "Enable AWS Config recorder + baseline rules (CC4/CC7). NOTE: the recorder is an account/region singleton — will conflict if one already exists."
  type        = bool
  default     = true
}

variable "enable_securityhub" {
  description = "Enable Security Hub + AWS Foundational Security Best Practices standard (CC4/CC7)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto created resources."
  type        = map(string)
  default     = {}
}
