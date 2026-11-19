"""SQS worker: emails the tutor on new uploads (from S3 events) and students when results are released."""
import json
import os
from urllib.parse import unquote_plus

import boto3

import db

ses = boto3.client("ses")
SENDER = os.environ["SES_SENDER"]
TUTOR = os.environ["TUTOR_EMAIL"]


def send(to, subject, text):
    ses.send_email(Source=SENDER, Destination={"ToAddresses": [to]},
                   Message={"Subject": {"Data": subject}, "Body": {"Text": {"Data": text}}})


def handle(msg):
    if msg.get("type") == "release":
        for r in db.rows("select email from attempts where exam_id=:e and email<>''", e=msg["exam_id"]):
            send(r["email"], "Your exam result is available", "Your result has been released. Please sign in to view it.")
        return
    for rec in msg.get("Records", []):  # S3 ObjectCreated event (s3:TestEvent has no Records)
        key = unquote_plus(rec["s3"]["object"]["key"])
        row = (db.rows("select email from uploads where s3_key=:k", k=key) or [{"email": "unknown"}])[0]
        send(TUTOR, "New assignment submission", f"{row['email']} uploaded {key.rsplit('/', 1)[-1]} ({rec['s3']['object'].get('size', '?')} bytes).")


def handler(event, _ctx):
    failures = []
    for rec in event["Records"]:
        try:
            handle(json.loads(rec["body"]))
        except Exception as exc:  # noqa: BLE001
            print("notify failed", rec["messageId"], exc)
            failures.append({"itemIdentifier": rec["messageId"]})
    return {"batchItemFailures": failures}
