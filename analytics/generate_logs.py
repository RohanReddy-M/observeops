"""Generate sample ObserveOps-style JSON logs for the analytics pipeline.

Mirrors the structured JSON log lines the real services emit (one JSON object
per line, written to stdout and shipped by Alloy to Loki). Deliberately
injects a few malformed rows and duplicate request_ids so the pipeline's data
quality gates have something real to catch.

Pure Python, no dependencies:  python generate_logs.py [days]
"""
import json
import os
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone

BASE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(BASE, "data", "raw")

SERVICES = {
    "secureship": ["/api/v1/ships", "/api/v1/ships/{id}", "/health"],
    "statusservice": ["/status", "/status/load", "/health"],
    "ragservice": ["/ai/query", "/ai/ingest", "/health"],
}
METHODS = ["GET", "GET", "GET", "POST", "PUT", "DELETE"]
ERROR_RATE = {"secureship": 0.02, "statusservice": 0.10, "ragservice": 0.05}
BASE_LATENCY_MS = {"secureship": 25, "statusservice": 15, "ragservice": 900}


def make_line(ts, service):
    path = random.choice(SERVICES[service])
    method = "GET" if path == "/health" else random.choice(METHODS)
    r = random.random()
    err_p = ERROR_RATE[service]
    if r < err_p:
        status = 500
    elif r < err_p + 0.01:
        status = 429
    elif r < err_p + 0.03:
        status = 404
    else:
        status = 200
    duration = round(random.lognormvariate(0, 0.6) * BASE_LATENCY_MS[service], 2)
    return {
        "timestamp": ts.isoformat(),
        "level": "ERROR" if status >= 500 else "INFO",
        "message": "request",
        "logger": service,
        "service": service,
        "request_id": str(uuid.uuid4()),
        "method": method,
        "path": path,
        "status_code": status,
        "duration_ms": duration,
    }


def main(days=3, per_day=20000, seed=42):
    random.seed(seed)
    os.makedirs(OUT_DIR, exist_ok=True)
    start = datetime.now(timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    ) - timedelta(days=days)
    total = 0
    for d in range(days):
        day = start + timedelta(days=d)
        fname = os.path.join(OUT_DIR, f"logs-{day.date()}.jsonl")
        lines = []
        for _ in range(per_day):
            ts = day + timedelta(seconds=random.uniform(0, 86400))
            service = random.choices(list(SERVICES), weights=[6, 3, 1])[0]
            lines.append(make_line(ts, service))

        # Data-quality traps, on purpose:
        # 1) duplicates — a retried request that got logged twice
        for dup in random.sample(lines, per_day // 100):
            lines.append(dict(dup))
        # 2) malformed rows — a required field missing
        for bad in random.sample(lines, per_day // 200):
            bad = dict(bad)
            if random.random() < 0.5:
                bad["status_code"] = None
            else:
                bad["request_id"] = None
            lines.append(bad)

        lines.sort(key=lambda x: x["timestamp"])
        with open(fname, "w", encoding="utf-8") as f:
            for obj in lines:
                f.write(json.dumps(obj) + "\n")
        total += len(lines)
        print(f"wrote {fname} ({len(lines)} lines)")
    print(f"total lines: {total}")


if __name__ == "__main__":
    main(days=int(sys.argv[1]) if len(sys.argv) > 1 else 3)
