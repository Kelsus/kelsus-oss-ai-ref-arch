variable "bucket_name" {
  description = "Globally-unique S3 bucket name for model weights."
  type        = string
}

variable "kms_alias" {
  description = "Alias for the CMK encrypting the bucket."
  type        = string
}

variable "env" {
  description = "Environment name (for tags)."
  type        = string
}

variable "reader_role_arns" {
  description = "IAM role ARNs (e.g. the inference IRSA/Pod-Identity role) allowed to read weights. Empty in Sprint 0; wired when serving lands."
  type        = list(string)
  default     = []
}
