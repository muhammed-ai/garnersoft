import json
import urllib.request
import urllib.error
import boto3
import os

def get_secret():
    client = boto3.client("secretsmanager", region_name=os.environ["AWS_REGION"])
    response = client.get_secret_value(SecretId=os.environ["SECRET_NAME"])
    secret = json.loads(response["SecretString"])
    return secret["brevo_api_key"]

def handler(event, context):
    headers = {
        "Access-Control-Allow-Origin": "https://garnersoft.com",
        "Access-Control-Allow-Methods": "POST,OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
    }

    # Handle CORS preflight
    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode": 200, "headers": headers, "body": ""}

    try:
        body = json.loads(event.get("body", "{}"))
        email = body.get("email", "").strip().lower()

        if not email or "@" not in email:
            return {
                "statusCode": 400,
                "headers": headers,
                "body": json.dumps({"message": "Invalid email address."})
            }

        api_key = get_secret()

        # Add contact to Brevo
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
            # 400 with "Contact already exist" is fine
            if e.code == 400 and "already exist" in error_body.lower():
                pass
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
