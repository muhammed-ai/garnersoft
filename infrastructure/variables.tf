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

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to deploy subnets into"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
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
