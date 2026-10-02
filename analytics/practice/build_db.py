"""Build practice.db (SQLite) from the generated logs so you can practice SQL with zero setup.

Run once:  python analytics/practice/build_db.py
Then:      python analytics/practice/sql.py
"""
import glob
import json
import os
import sqlite3

BASE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(BASE, "..", "data", "raw", "*.jsonl")
DB = os.path.join(BASE, "practice.db")

con = sqlite3.connect(DB)
cur = con.cursor()
cur.executescript(
    """
    DROP TABLE IF EXISTS requests;
    DROP TABLE IF EXISTS services;
    CREATE TABLE requests(
        request_id  TEXT,
        service     TEXT,
        path        TEXT,
        method      TEXT,
        status_code INTEGER,
        duration_ms REAL,
        ts          TEXT
    );
    CREATE TABLE services(
        service TEXT PRIMARY KEY,
        team    TEXT,
        owner   TEXT
    );
    """
)

rows = []
for p in sorted(glob.glob(RAW)):
    with open(p, encoding="utf-8") as f:
        for line in f:
            r = json.loads(line)
            rows.append(
                (r["request_id"], r["service"], r["path"], r["method"],
                 r["status_code"], r["duration_ms"], r["timestamp"])
            )
cur.executemany("INSERT INTO requests VALUES (?,?,?,?,?,?,?)", rows)

# 'billing' has no requests on purpose — it's there so LEFT JOIN vs INNER JOIN shows a difference.
cur.executemany(
    "INSERT INTO services VALUES (?,?,?)",
    [("secureship", "platform", "rohan"), ("statusservice", "platform", "rohan"),
     ("ragservice", "ai", "rohan"), ("billing", "payments", "asha")],
)
con.commit()
print(f"loaded {len(rows)} rows into requests, 4 rows into services -> {DB}")
