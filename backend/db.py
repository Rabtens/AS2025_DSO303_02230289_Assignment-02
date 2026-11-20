"""Shared PostgreSQL access over TLS using IAM or Secrets Manager."""
import json
import os
import ssl

import boto3
import pg8000.native

_conn = None
_password = None

SCHEMA = [
    """create table if not exists exams(
        id serial primary key, title text not null, duration_min int not null,
        questions text not null, released boolean not null default false, created_by text)""",
    """create table if not exists attempts(
        exam_id int not null, student text not null, email text,
        started_at timestamptz not null default now(), submitted_at timestamptz,
        answers text not null default '{}', saved_at timestamptz, score numeric,
        primary key(exam_id, student))""",
    """create table if not exists uploads(
        id serial primary key, student text not null, email text,
        s3_key text unique not null, created_at timestamptz not null default now())""",
]


def _get_password():
    secret_arn = os.environ["DB_SECRET_ARN"]
    if not secret_arn:
        return boto3.client("rds").generate_db_auth_token(
            DBHostname=os.environ["DB_HOST"],
            Port=5432,
            DBUsername=os.environ["DB_USER"],
        )

    global _password
    if _password is None:
        secret = boto3.client("secretsmanager").get_secret_value(SecretId=secret_arn)
        _password = json.loads(secret["SecretString"])["password"]
    return _password


def _connect():
    conn = pg8000.native.Connection(
        user=os.environ["DB_USER"],
        host=os.environ["DB_HOST"],
        database=os.environ["DB_NAME"],
        password=_get_password(),
        ssl_context=ssl.create_default_context(),
        timeout=10,
    )
    conn.run("BEGIN")
    conn.run("select pg_advisory_xact_lock(42)")  # serialise concurrent cold starts
    for stmt in SCHEMA:
        conn.run(stmt)
    conn.run("COMMIT")
    return conn


def rows(sql, **params):
    """Run a statement and return a list of dicts. Reconnects once if the connection went stale
    (for example after an Aurora failover)."""
    global _conn
    for attempt in (1, 2):
        try:
            if _conn is None:
                _conn = _connect()
            result = _conn.run(sql, **params)
            cols = [c["name"] for c in (_conn.columns or [])]
            return [dict(zip(cols, r)) for r in (result or [])]
        except (pg8000.exceptions.InterfaceError, pg8000.exceptions.DatabaseError, OSError):
            try:
                _conn.close()
            except Exception:
                pass
            _conn = None
            if attempt == 2:
                raise
    return []
