#!/bin/bash
dnf install -y python3-pip
mkdir -p /opt/calculator
cat > /opt/calculator/app.py << 'PYEOF'
import shutil
from flask import Flask, request, jsonify

app = Flask(__name__)

OPERATIONS = {
    "add": lambda a, b: a + b,
    "subtract": lambda a, b: a - b,
    "multiply": lambda a, b: a * b,
    "divide": lambda a, b: a / b,
}


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

    return jsonify(result=OPERATIONS[op](a, b))


@app.route("/health")
def health():
    disk = shutil.disk_usage("/")
    free_pct = round(disk.free / disk.total * 100, 1)
    status = "ok" if free_pct > 10 else "degraded"
    return jsonify(
        status=status,
        disk_free_percent=free_pct,
    ), (200 if status == "ok" else 503)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
PYEOF

pip3 install flask==3.0.3

cat > /etc/systemd/system/calculator.service << 'SVCEOF'
[Unit]
Description=Calculator Ops Lab App
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/calculator/app.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now calculator.service
