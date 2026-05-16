import json
import urllib.request
import urllib.error
import base64
import boto3
import os

def get_secret():
    client = boto3.client("secretsmanager", region_name=os.environ.get("SECRET_REGION", "us-east-1"))
    response = client.get_secret_value(SecretId=os.environ["SECRET_NAME"])
    secret_string = response["SecretString"]
    # Handle both plain string and JSON-wrapped secret
    try:
        secret = json.loads(secret_string)
        return secret["brevo_api_key"]
    except (json.JSONDecodeError, KeyError):
        # Secret is stored as plain API key string
        return secret_string.strip()

def handler(event, context):
    print("Event:", json.dumps(event))

    headers = {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST,OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
    }

    # Handle CORS preflight
    method = event.get("httpMethod") or event.get("requestContext", {}).get("http", {}).get("method", "")
    if method == "OPTIONS":
        return {"statusCode": 200, "headers": headers, "body": ""}

    try:
        # Handle base64-encoded body (API Gateway may encode it)
        raw_body = event.get("body", "{}")
        if event.get("isBase64Encoded", False):
            raw_body = base64.b64decode(raw_body).decode("utf-8")

        if not raw_body:
            raw_body = "{}"

        body = json.loads(raw_body)
        email = body.get("email", "").strip().lower()

        if not email or "@" not in email:
            return {
                "statusCode": 400,
                "headers": headers,
                "body": json.dumps({"message": "Invalid email address."})
            }

        api_key = get_secret()

        payload = json.dumps({
            "email": email,
            "listIds": [int(os.environ["BREVO_LIST_ID"])],
            "updateEnabled": True
        }).encode("utf-8")

        req = urllib.request.Request(
            "https://api.brevo.com/v3/contacts",
            data=payload,
            headers={
                "accept": "application/json",
                "content-type": "application/json",
                "api-key": api_key,
            },
            method="POST"
        )

        try:
            urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            error_body = e.read().decode()
            print(f"Brevo error {e.code}: {error_body}")
            if e.code == 400 and "already exist" in error_body.lower():
                pass  # already subscribed is fine
            else:
                raise

        return {
            "statusCode": 200,
            "headers": headers,
            "body": json.dumps({"message": "You're on the list!"})
        }

    except Exception as e:
        print(f"Error: {e}")
        return {
            "statusCode": 500,
            "headers": headers,
            "body": json.dumps({"message": "Something went wrong. Please try again."})
        }
