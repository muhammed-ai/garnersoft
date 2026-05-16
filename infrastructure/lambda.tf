# ── SECRETS MANAGER ───────────────────────────────────────────────────────

# Stores the Brevo API key securely. The actual secret value must be set
# manually after terraform apply using the AWS CLI or Console — it is never
# stored in code or state in plaintext.
resource "aws_secretsmanager_secret" "brevo" {
  name        = "garnersoft/brevo-api-key"
  description = "Brevo API key for the Garnersoft Academy waitlist"
  tags        = local.common_tags
}

# Placeholder — set the real value manually after apply:
# aws secretsmanager put-secret-value \
#   --secret-id garnersoft/brevo-api-key \
#   --secret-string '{"brevo_api_key":"YOUR_NEW_KEY_HERE"}'
resource "aws_secretsmanager_secret_version" "brevo" {
  secret_id     = aws_secretsmanager_secret.brevo.id
  secret_string = jsonencode({ brevo_api_key = "REPLACE_AFTER_APPLY" })

  lifecycle {
    # Prevent Terraform from overwriting the real key once set manually
    ignore_changes = [secret_string]
  }
}

# ── LAMBDA ZIP ─────────────────────────────────────────────────────────────

# Packages the Lambda function code into a zip file for deployment.
data "archive_file" "waitlist" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_function"
  output_path = "${path.module}/lambda_function.zip"
}

# ── IAM ROLE FOR LAMBDA ────────────────────────────────────────────────────

# IAM role that Lambda assumes at runtime. Grants only the minimum permissions
# needed: write logs to CloudWatch and read the Brevo secret from Secrets Manager.
resource "aws_iam_role" "lambda_waitlist" {
  name = "garnersoft-waitlist-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# Allows Lambda to write execution logs to CloudWatch for debugging.
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_waitlist.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Grants Lambda read-only access to the specific Brevo secret.
# Scoped to only this secret — not all secrets in the account.
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "garnersoft-waitlist-secrets-policy"
  role = aws_iam_role.lambda_waitlist.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.brevo.arn
    }]
  })
}

# ── LAMBDA FUNCTION ────────────────────────────────────────────────────────

# The Lambda function receives the email from the waitlist form, fetches the
# Brevo API key from Secrets Manager, and adds the contact to the Brevo list.
resource "aws_lambda_function" "waitlist" {
  function_name    = "garnersoft-waitlist"
  filename         = data.archive_file.waitlist.output_path
  source_code_hash = data.archive_file.waitlist.output_base64sha256
  role             = aws_iam_role.lambda_waitlist.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 10

  environment {
    variables = {
      SECRET_NAME   = aws_secretsmanager_secret.brevo.name
      BREVO_LIST_ID = var.brevo_list_id
    }
  }

  tags = local.common_tags
}

# ── API GATEWAY ────────────────────────────────────────────────────────────

# HTTP API Gateway exposes the Lambda as a public HTTPS endpoint.
# The frontend form POSTs to this URL — no server needed.
resource "aws_apigatewayv2_api" "waitlist" {
  name          = "garnersoft-waitlist-api"
  protocol_type = "HTTP"
  description   = "API Gateway for the Garnersoft Academy waitlist form"

  # CORS configuration allows the form on garnersoft.com to call this endpoint.
  cors_configuration {
    allow_origins = ["https://garnersoft.com", "https://www.garnersoft.com"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
    max_age       = 300
  }

  tags = local.common_tags
}

# Connects API Gateway to the Lambda function.
resource "aws_apigatewayv2_integration" "waitlist" {
  api_id                 = aws_apigatewayv2_api.waitlist.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.waitlist.invoke_arn
  payload_format_version = "2.0"
}

# Route: POST /waitlist → Lambda
resource "aws_apigatewayv2_route" "waitlist" {
  api_id    = aws_apigatewayv2_api.waitlist.id
  route_key = "POST /waitlist"
  target    = "integrations/${aws_apigatewayv2_integration.waitlist.id}"
}

# Auto-deploy stage — changes go live immediately after apply.
resource "aws_apigatewayv2_stage" "waitlist" {
  api_id      = aws_apigatewayv2_api.waitlist.id
  name        = "$default"
  auto_deploy = true

  tags = local.common_tags
}

# Grants API Gateway permission to invoke the Lambda function.
resource "aws_lambda_permission" "waitlist" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.waitlist.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.waitlist.execution_arn}/*/*"
}
