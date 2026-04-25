variable "domain_name" {
  description = "The domain name for the website (e.g. garnersoft.com)"
  type        = string
  default     = "garnersoft.com"
}

variable "aws_region" {
  description = "Primary AWS region for S3 and other resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"
}

locals {
  common_tags = {
    Project     = "Garnersoft"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = "Garnersoft"
    Repository  = "garnersoft/garnersoft"
  }
}
