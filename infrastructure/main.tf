terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote backend stores tfstate in S3 so the team shares a single source of
  # truth and avoids state conflicts when multiple people run Terraform.
  backend "s3" {
    bucket = "garnersoft-terraform-state"
    key    = "frontend/terraform.tfstate"
    region = "us-east-1"
  }
}

# Primary provider — all resources default to this region unless overridden.
provider "aws" {
  region = var.aws_region
}

# CloudFront requires ACM certificates to exist in us-east-1 regardless of
# where the rest of the infrastructure lives, so a second aliased provider
# is needed to create the certificate in the correct region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# ── S3 BUCKET ──────────────────────────────────────────────────────────────

# The S3 bucket is the origin store for all static website files (HTML, CSS).
# The bucket is kept fully private — only CloudFront can access it via OAC.
resource "aws_s3_bucket" "website" {
  bucket = var.domain_name
  tags   = local.common_tags
}

# All public access is blocked. The bucket is private and only accessible
# by CloudFront via the Origin Access Control policy below.
# This prevents anyone from bypassing CloudFront and hitting S3 directly.
resource "aws_s3_bucket_public_access_block" "website" {
  bucket = aws_s3_bucket.website.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning keeps a history of every file uploaded to the bucket.
# This allows rollback to a previous deployment if a bad release is pushed.
resource "aws_s3_bucket_versioning" "website" {
  bucket = aws_s3_bucket.website.id
  versioning_configuration { status = "Enabled" }
  tags   = local.common_tags
}

# Origin Access Control (OAC) is the AWS-recommended way to connect
# CloudFront to a private S3 bucket. It replaces the older Origin Access
# Identity (OAI) approach and uses SigV4 request signing so S3 can verify
# every request came from this specific CloudFront distribution.
resource "aws_cloudfront_origin_access_control" "website" {
  name                              = "${var.domain_name}-oac"
  description                       = "OAC for ${var.domain_name} S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Grants CloudFront read-only access to the S3 bucket via OAC.
# The condition locks access to this specific CloudFront distribution ARN
# so no other distribution or principal can read from this bucket.
resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.website.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.website.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.website]
}

# ── ACM CERTIFICATE ────────────────────────────────────────────────────────

# A free TLS certificate from AWS Certificate Manager enables HTTPS on the
# CloudFront distribution. Must be provisioned in us-east-1 for CloudFront.
# Covers both the apex domain and the www subdomain.
resource "aws_acm_certificate" "website" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = ["www.${var.domain_name}"]

  tags = local.common_tags

  # create_before_destroy ensures zero-downtime certificate rotation —
  # the new cert is issued before the old one is destroyed.
  lifecycle { create_before_destroy = true }
}

# ACM DNS validation requires CNAME records to be added to Route 53 so AWS
# can verify domain ownership before issuing the certificate.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.website.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.website.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

# Waits for ACM to complete DNS validation before Terraform proceeds.
# Without this, CloudFront would try to attach an unvalidated certificate
# and the apply would fail.
resource "aws_acm_certificate_validation" "website" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.website.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ── CLOUDFRONT ─────────────────────────────────────────────────────────────

# CloudFront is a global CDN that sits in front of S3 and provides:
#   - HTTPS termination using the ACM certificate
#   - Edge caching so files are served from the nearest AWS PoP worldwide
#   - HTTP → HTTPS redirect enforcement
#   - Gzip/Brotli compression to reduce payload size
#   - Custom cache rules (long TTL for assets, no-cache for HTML)
#   - 403/404 error handling redirected to index.html
resource "aws_cloudfront_distribution" "website" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [var.domain_name, "www.${var.domain_name}"]
  # PriceClass_100 limits edge locations to North America and Europe,
  # reducing cost while covering the primary target audience.
  price_class = "PriceClass_100"
  comment     = "${var.domain_name} website"
  tags        = local.common_tags

  # Points CloudFront to the S3 REST endpoint (not the website endpoint)
  # because OAC requires the REST endpoint for SigV4 request signing.
  # The bucket_regional_domain_name is used instead of the website endpoint.
  origin {
    origin_id                = "s3-oac"
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.website.id
  }

  # Default cache behaviour applies to all files except those matched by
  # ordered_cache_behavior below. Assets (CSS, images) are cached for 1 year
  # since their content is immutable once deployed.
  default_cache_behavior {
    target_origin_id       = "s3-oac"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000
  }

  # HTML files must never be cached so users always receive the latest version
  # immediately after a deployment without needing a manual cache invalidation.
  ordered_cache_behavior {
    path_pattern           = "*.html"
    target_origin_id       = "s3-oac"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # S3 returns 403 for missing objects (not 404) when using bucket policies.
  # Both are mapped to index.html so the single-page site handles routing.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  # Attaches the validated ACM certificate to enable HTTPS.
  # sni-only is the modern standard and avoids the legacy dedicated IP cost.
  # TLSv1.2_2021 enforces modern TLS and disables older insecure versions.
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.website.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.website]
}

# ── ROUTE 53 ───────────────────────────────────────────────────────────────

# Looks up the existing Route 53 hosted zone for the domain. The zone must
# already exist (created when the domain was registered or transferred).
data "aws_route53_zone" "website" {
  name         = var.domain_name
  private_zone = false
}

# Apex A record (garnersoft.com) aliased to CloudFront so DNS resolves
# directly to the nearest CloudFront edge location. An alias record is
# preferred over a CNAME at the apex because CNAME at root is not valid DNS.
resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.website.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}

# www subdomain A record aliased to the same CloudFront distribution so both
# garnersoft.com and www.garnersoft.com resolve to the same website.
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.website.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}

