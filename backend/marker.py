"""SQS worker: auto-marks MCQs after submission. Short answers stay for the tutor."""
import json

import db


def mark(exam_id, student):
    exam = db.rows("select questions from exams where id=:i", i=exam_id)[0]
    att = db.rows("select answers from attempts where exam_id=:e and student=:s", e=exam_id, s=student)[0]
    answers = json.loads(att["answers"])
    score = sum(q.get("points", 1) for q in json.loads(exam["questions"])
                if q["type"] == "mcq" and answers.get(q["id"]) == q["answer"])
    db.rows("update attempts set score=:sc where exam_id=:e and student=:s", sc=score, e=exam_id, s=student)


def handler(event, _ctx):
    failures = []
    for rec in event["Records"]:
        try:
            msg = json.loads(rec["body"])
            mark(msg["exam_id"], msg["student"])  # idempotent: re-marking gives the same score
        except Exception as exc:  # noqa: BLE001
            print("marking failed", rec["messageId"], exc)
            failures.append({"itemIdentifier": rec["messageId"]})
    return {"batchItemFailures": failures}
