"""Python practice for the L1 — the kind of task an interviewer types into a shared doc.

Fill in each function (replace `raise NotImplementedError`), then run:
    python analytics/practice/python_exercises.py
It prints PASS / FAIL per task. Solutions: python_solutions.py (read only after trying).
"""
import collections
import inspect
import sys

# A tiny fixed dataset so the checks are exact. Same shape as the real log rows.
SAMPLE = [
    {"request_id": "a", "service": "secureship",    "path": "/api/v1/ships", "status_code": 200,  "duration_ms": 10.0},
    {"request_id": "b", "service": "secureship",    "path": "/api/v1/ships", "status_code": 500,  "duration_ms": 30.0},
    {"request_id": "b", "service": "secureship",    "path": "/api/v1/ships", "status_code": 500,  "duration_ms": 30.0},  # duplicate
    {"request_id": "c", "service": "ragservice",    "path": "/ai/query",     "status_code": 200,  "duration_ms": 900.0},
    {"request_id": "d", "service": "ragservice",    "path": "/ai/query",     "status_code": 503,  "duration_ms": 1200.0},
    {"request_id": "e", "service": "statusservice", "path": "/status",       "status_code": None, "duration_ms": 5.0},   # malformed
    {"request_id": "f", "service": "secureship",    "path": "/health",       "status_code": 200,  "duration_ms": 20.0},
]


# 1. Count requests per service. Return a dict {service: count}.
def count_per_service(rows):
    raise NotImplementedError


# 2. Error count per service: status_code >= 500. Skip rows whose status_code is None.
#    Return a dict with only the services that have errors.
def errors_per_service(rows):
    raise NotImplementedError


# 3. Remove duplicate request_ids, keeping the FIRST occurrence. Return a list, original order.
def dedupe(rows):
    raise NotImplementedError


# 4. The n slowest rows (by duration_ms) for one service, slowest first. Return a list of rows.
def slowest(rows, service, n=3):
    raise NotImplementedError


# 5. Average duration per path, rounded to 2 decimals. Return a dict {path: avg}.
def avg_duration_per_path(rows):
    raise NotImplementedError


# 6. A GENERATOR that yields only error rows (status_code >= 500). Do not build a list.
def error_rows(rows):
    raise NotImplementedError


# 7. Most common word in a list and its count, as a tuple ("word", count).
def most_common_word(words):
    raise NotImplementedError


# 8. Reverse a string without using slicing [::-1].
def reverse(s):
    raise NotImplementedError


# ── checker ────────────────────────────────────────────────────────────────────
def run_checks(mod):
    checks = [
        ("1 count_per_service", lambda: dict(mod.count_per_service(SAMPLE)) == {"secureship": 4, "ragservice": 2, "statusservice": 1}),
        ("2 errors_per_service", lambda: dict(mod.errors_per_service(SAMPLE)) == {"secureship": 2, "ragservice": 1}),
        ("3 dedupe", lambda: [r["request_id"] for r in mod.dedupe(SAMPLE)] == ["a", "b", "c", "d", "e", "f"]),
        ("4 slowest", lambda: [r["duration_ms"] for r in mod.slowest(SAMPLE, "secureship", 2)] == [30.0, 30.0]),
        ("5 avg_duration_per_path", lambda: mod.avg_duration_per_path(SAMPLE) == {"/api/v1/ships": 23.33, "/ai/query": 1050.0, "/status": 5.0, "/health": 20.0}),
        ("6 error_rows is a generator", lambda: inspect.isgenerator(mod.error_rows(SAMPLE)) and [r["request_id"] for r in mod.error_rows(SAMPLE)] == ["b", "b", "d"]),
        ("7 most_common_word", lambda: tuple(mod.most_common_word(["a", "b", "a", "c", "a", "b"])) == ("a", 3)),
        ("8 reverse", lambda: mod.reverse("spark") == "kraps"),
    ]
    passed = 0
    for name, fn in checks:
        try:
            ok = bool(fn())
        except NotImplementedError:
            ok, note = False, "(not attempted)"
        except Exception as e:
            ok, note = False, f"({type(e).__name__}: {e})"
        else:
            note = ""
        passed += ok
        print(f"{'PASS' if ok else 'FAIL'}  {name} {note}")
    print(f"\n{passed}/{len(checks)} passed")


if __name__ == "__main__":
    run_checks(sys.modules[__name__])
