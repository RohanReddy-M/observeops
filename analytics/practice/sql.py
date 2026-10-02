"""Tiny SQL workspace over practice.db.

  python analytics/practice/sql.py                      -> interactive: type a query ending in ; then Enter
  python analytics/practice/sql.py "SELECT ... ;"        -> run one query

Tables:
  requests(request_id, service, path, method, status_code, duration_ms, ts)
  services(service, team, owner)
"""
import os
import sqlite3
import sys

DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "practice.db")
con = sqlite3.connect(DB)


def run(query, limit=30):
    try:
        cur = con.execute(query)
        if cur.description:
            cols = [d[0] for d in cur.description]
            rows = cur.fetchmany(limit)
            widths = [max(len(c), *(len(str(r[i])) for r in rows)) if rows else len(c) for i, c in enumerate(cols)]
            print("  ".join(c.ljust(w) for c, w in zip(cols, widths)))
            print("  ".join("-" * w for w in widths))
            for r in rows:
                print("  ".join(str(v).ljust(w) for v, w in zip(r, widths)))
            print(f"({len(rows)} rows shown, max {limit})")
        else:
            con.commit()
            print("ok")
    except Exception as e:  # show the error, keep going
        print("ERROR:", e)


if len(sys.argv) > 1:
    run(" ".join(sys.argv[1:]))
else:
    print(__doc__)
    buf = ""
    while True:
        try:
            line = input("sql> " if not buf else "...> ")
        except EOFError:
            break
        if line.strip().lower() in ("quit", "exit"):
            break
        buf += " " + line
        if line.strip().endswith(";"):
            run(buf.strip())
            buf = ""
