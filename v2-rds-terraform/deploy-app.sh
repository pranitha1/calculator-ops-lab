#!/bin/bash
set -e
systemctl stop calculator || true
pip3 install boto3 psycopg2-binary

cat > /opt/calculator/app.py << 'PYEOF'
import shutil
import boto3
import psycopg2
from flask import Flask, request, jsonify

app = Flask(__name__)

OPERATIONS = {
    "add": lambda a, b: a + b,
    "subtract": lambda a, b: a - b,
    "multiply": lambda a, b: a * b,
    "divide": lambda a, b: a / b,
}


def get_ssm_param(name, decrypt=False):
    ssm = boto3.client("ssm", region_name="us-east-1")
    return ssm.get_parameter(Name=name, WithDecryption=decrypt)["Parameter"]["Value"]


DB_CONFIG = {
    "host": get_ssm_param("/calculator/db_host"),
    "dbname": get_ssm_param("/calculator/db_name"),
    "user": get_ssm_param("/calculator/db_user"),
    "password": get_ssm_param("/calculator/db_password", decrypt=True),
}


def get_connection():
    return psycopg2.connect(**DB_CONFIG)


def init_db():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS calculations (
                    id SERIAL PRIMARY KEY,
                    operation TEXT NOT NULL,
                    a DOUBLE PRECISION NOT NULL,
                    b DOUBLE PRECISION NOT NULL,
                    result DOUBLE PRECISION NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
            """)
            conn.commit()


@app.route("/calculate", methods=["POST"])
def calculate():
    data = request.get_json(silent=True) or {}
    op = data.get("operation")
    a = data.get("a")
    b = data.get("b")

    if op not in OPERATIONS:
        return jsonify(error=f"unsupported operation '{op}'"), 400
    if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
        return jsonify(error="'a' and 'b' must be numbers"), 400
    if op == "divide" and b == 0:
        return jsonify(error="division by zero"), 400

    result = OPERATIONS[op](a, b)

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO calculations (operation, a, b, result) VALUES (%s, %s, %s, %s)",
                (op, a, b, result),
            )
            conn.commit()

    return jsonify(result=result)


@app.route("/history")
def history():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT operation, a, b, result, created_at FROM calculations "
                "ORDER BY id DESC LIMIT 20"
            )
            rows = cur.fetchall()

    return jsonify(history=[
        {"operation": r[0], "a": r[1], "b": r[2], "result": r[3], "created_at": r[4].isoformat()}
        for r in rows
    ])


@app.route("/health")
def health():
    disk = shutil.disk_usage("/")
    free_pct = round(disk.free / disk.total * 100, 1)

    db_ok = True
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
    except Exception:
        db_ok = False

    status = "ok" if free_pct > 10 and db_ok else "degraded"
    return jsonify(
        status=status,
        disk_free_percent=free_pct,
        db_ok=db_ok,
    ), (200 if status == "ok" else 503)


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=5000)
PYEOF

systemctl start calculator
sleep 2
systemctl is-active calculator
curl -s localhost:5000/health
