output "s3_bucket_name" {
  description = "Name of the S3 website bucket"
  value       = aws_s3_bucket.website.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — used for cache invalidation in the deploy pipeline"
  value       = aws_cloudfront_distribution.website.id
}

output "cloudfront_domain_name" {
  description = "CloudFront domain name"
  value       = aws_cloudfront_distribution.website.domain_name
}

output "website_url" {
  description = "Live website URL"
  value       = "https://${var.domain_name}"
}

# ── NETWORKING OUTPUTS ─────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "public_security_group_id" {
  description = "Security group ID for public-facing resources"
  value       = aws_security_group.public.id
}

output "private_security_group_id" {
  description = "Security group ID for private resources"
  value       = aws_security_group.private.id
}
