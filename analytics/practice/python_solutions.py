"""Solutions for python_exercises.py — read only after trying. Run: python analytics/practice/python_solutions.py"""
import collections
import sys

from python_exercises import SAMPLE, run_checks  # noqa: F401


# 1. dict as an accumulator — the single most common interview pattern
def count_per_service(rows):
    counts = {}
    for r in rows:
        counts[r["service"]] = counts.get(r["service"], 0) + 1
    return counts
    # one-liner: return dict(collections.Counter(r["service"] for r in rows))


# 2. same shape, with a condition; None is skipped because None >= 500 would raise
def errors_per_service(rows):
    errors = {}
    for r in rows:
        if r["status_code"] is not None and r["status_code"] >= 500:
            errors[r["service"]] = errors.get(r["service"], 0) + 1
    return errors


# 3. a set remembers what you've seen — O(1) membership
def dedupe(rows):
    seen, out = set(), []
    for r in rows:
        if r["request_id"] not in seen:
            seen.add(r["request_id"])
            out.append(r)
    return out


# 4. filter, then sort with a key, descending, then slice
def slowest(rows, service, n=3):
    mine = [r for r in rows if r["service"] == service]
    return sorted(mine, key=lambda r: r["duration_ms"], reverse=True)[:n]


# 5. collect values per key, then average — two passes, clear
def avg_duration_per_path(rows):
    totals = collections.defaultdict(list)
    for r in rows:
        totals[r["path"]].append(r["duration_ms"])
    return {path: round(sum(v) / len(v), 2) for path, v in totals.items()}


# 6. yield instead of append — nothing is built in memory
def error_rows(rows):
    for r in rows:
        if r["status_code"] is not None and r["status_code"] >= 500:
            yield r


# 7. Counter does the counting; most_common(1) returns [(word, count)]
def most_common_word(words):
    return collections.Counter(words).most_common(1)[0]


# 8. build it back to front
def reverse(s):
    out = ""
    for ch in s:
        out = ch + out
    return out
    # also fine: "".join(reversed(s))


if __name__ == "__main__":
    run_checks(sys.modules[__name__])
