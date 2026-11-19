"""HTTP API behind API Gateway (payload v2). Cognito JWT is already verified by the gateway."""
import json
import os
import re
import uuid

import boto3
from botocore.config import Config

import db

REGION = os.environ["AWS_REGION"]
BUCKET = os.environ["UPLOAD_BUCKET"]
MAX_BYTES = 50 * 1024 * 1024
s3 = boto3.client("s3", region_name=REGION, endpoint_url=f"https://s3.{REGION}.amazonaws.com",
                  config=Config(signature_version="s3v4"))
sqs = boto3.client("sqs")


def resp(code, body):
    return {"statusCode": code, "headers": {"content-type": "application/json"}, "body": json.dumps(body, default=str)}


def groups_of(claims):
    raw = claims.get("cognito:groups", "")
    return set(re.findall(r"[\w-]+", raw if isinstance(raw, str) else " ".join(raw)))


def strip_answers(questions):
    return [{k: v for k, v in q.items() if k != "answer"} for q in questions]


def handler(event, _ctx):
    http = event["requestContext"]["http"]
    method, path = http["method"], http["path"]
    if path == "/api/health":
        return resp(200, {"ok": True})
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    user, email, groups = claims["sub"], claims.get("email", ""), groups_of(claims)
    is_tutor = bool(groups & {"tutor", "admin"})
    body = json.loads(event.get("body") or "{}")

    try:
        if (method, path) == ("GET", "/api/exams"):
            return resp(200, db.rows("select id,title,duration_min,released from exams order by id"))

        if (method, path) == ("POST", "/api/exams"):
            if not is_tutor:
                return resp(403, {"error": "tutors only"})
            r = db.rows("insert into exams(title,duration_min,questions,created_by) values(:t,:d,:q,:u) returning id",
                        t=body["title"], d=int(body["duration_min"]), q=json.dumps(body["questions"]), u=user)
            return resp(201, r[0])

        if (method, path) == ("POST", "/api/uploads/presign"):
            name = re.sub(r"[^A-Za-z0-9._-]", "_", body["filename"])[-100:]
            if not name.lower().endswith((".pdf", ".zip")):
                return resp(400, {"error": "only PDF or ZIP allowed"})
            if not 0 < int(body["size_bytes"]) <= MAX_BYTES:
                return resp(400, {"error": "file must be 1 byte to 50 MB"})
            key = f"uploads/{user}/{uuid.uuid4()}-{name}"
            ctype = "application/pdf" if name.lower().endswith(".pdf") else "application/zip"
            db.rows("insert into uploads(student,email,s3_key) values(:s,:e,:k)", s=user, e=email, k=key)
            post = s3.generate_presigned_post(
                BUCKET, key, Fields={"Content-Type": ctype},
                Conditions=[["content-length-range", 1, MAX_BYTES], {"Content-Type": ctype}], ExpiresIn=900)
            return resp(200, post)

        m = re.fullmatch(r"/api/exams/(\d+)(?:/(\w+))?", path)
        if m:
            exam_id, action = int(m.group(1)), m.group(2)
            exam = (db.rows("select * from exams where id=:i", i=exam_id) or [None])[0]
            if not exam:
                return resp(404, {"error": "no such exam"})
            questions = json.loads(exam["questions"])

            if method == "GET" and action is None:
                return resp(200, {**{k: exam[k] for k in ("id", "title", "duration_min", "released")},
                                  "questions": questions if is_tutor else strip_answers(questions)})

            if method == "POST" and action == "start":
                db.rows("insert into attempts(exam_id,student,email) values(:e,:s,:m) on conflict do nothing",
                        e=exam_id, s=user, m=email)
                a = db.rows("select started_at,submitted_at,answers,saved_at from attempts where exam_id=:e and student=:s",
                            e=exam_id, s=user)[0]
                a["answers"] = json.loads(a["answers"])
                return resp(200, a)

            if method == "PUT" and action == "answers":  # autosave, called every 30 s by the browser
                r = db.rows(
                    """update attempts set answers=:a, saved_at=now()
                       where exam_id=:e and student=:s and submitted_at is null
                         and now() <= started_at + make_interval(mins => :d) + interval '60 seconds'
                       returning saved_at""",
                    a=json.dumps(body["answers"]), e=exam_id, s=user, d=exam["duration_min"])
                return resp(200, r[0]) if r else resp(409, {"error": "attempt closed or not started"})

            if method == "POST" and action == "submit":
                r = db.rows("update attempts set submitted_at=now() where exam_id=:e and student=:s "
                            "and submitted_at is null returning exam_id", e=exam_id, s=user)
                if r:  # hand marking to the async worker
                    sqs.send_message(QueueUrl=os.environ["MARKING_QUEUE_URL"],
                                     MessageBody=json.dumps({"exam_id": exam_id, "student": user}))
                return resp(202, {"status": "submitted, marking queued"})

            if method == "POST" and action == "release":
                if not is_tutor:
                    return resp(403, {"error": "tutors only"})
                db.rows("update exams set released=true where id=:i", i=exam_id)
                sqs.send_message(QueueUrl=os.environ["NOTIFY_QUEUE_URL"],
                                 MessageBody=json.dumps({"type": "release", "exam_id": exam_id}))
                return resp(202, {"status": "released, emails queued"})

            if method == "GET" and action == "results":
                if is_tutor:
                    return resp(200, db.rows("select student,email,score,submitted_at from attempts where exam_id=:e", e=exam_id))
                if not exam["released"]:
                    return resp(403, {"error": "results not released"})
                return resp(200, db.rows("select score,submitted_at from attempts where exam_id=:e and student=:s", e=exam_id, s=user))

        return resp(404, {"error": "not found"})
    except KeyError as e:
        return resp(400, {"error": f"missing field {e}"})
