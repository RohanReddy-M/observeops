#!/usr/bin/env python3
"""
RAG Quality Evaluation Harness
-------------------------------
Runs 5 representative queries against a live RAGService instance and scores
each answer for keyword coverage.  Exits non-zero if any test case scores
below the threshold — used as a CI gate so prompt or document changes that
regress answer quality are caught before they reach production.

Usage:
    python eval.py                         # expects RAGService at localhost:8003
    RAGSERVICE_URL=http://host:8003 python eval.py
"""

import json
import os
import sys
import urllib.request
import urllib.error

BASE_URL = os.getenv("RAGSERVICE_URL", "http://localhost:8003")
PASS_THRESHOLD = 0.5   # fraction of keywords that must appear in the answer


TEST_CASES = [
    {
        "name": "high_cpu_diagnosis",
        "question": "The HighCPUUsage alert fired on the app server. What are the likely causes and how do I investigate?",
        "required_keywords": ["cpu", "top", "process", "docker", "container"],
    },
    {
        "name": "service_down_response",
        "question": "ServiceDown alert fired for secureship. What steps should I take to restore it?",
        "required_keywords": ["docker", "restart", "logs", "health", "container"],
    },
    {
        "name": "high_error_rate",
        "question": "HighErrorRate alert is firing at 15%. What does this mean and what should I check first?",
        "required_keywords": ["error", "logs", "5xx", "grafana", "loki"],
    },
    {
        "name": "disk_space_low",
        "question": "DiskSpaceLow alert fired. The disk is at 80% capacity. What should I clean up?",
        "required_keywords": ["docker", "prune", "logs", "disk", "images"],
    },
    {
        "name": "llm_high_error_rate",
        "question": "LLMHighErrorRate alert is firing. RAGService LLM calls are failing. What could be wrong?",
        "required_keywords": ["groq", "api", "key", "rate", "limit"],
    },
]


def query_ragservice(question: str) -> dict:
    payload = json.dumps({"question": question}).encode()
    req = urllib.request.Request(
        f"{BASE_URL}/ai/query",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def score_answer(answer: str, keywords: list[str]) -> tuple[float, list[str]]:
    answer_lower = answer.lower()
    matched = [kw for kw in keywords if kw.lower() in answer_lower]
    return len(matched) / len(keywords), matched


def run_eval() -> bool:
    print(f"RAG Quality Evaluation — {BASE_URL}\n{'=' * 50}")
    all_passed = True

    for tc in TEST_CASES:
        print(f"\n[{tc['name']}]")
        print(f"  Q: {tc['question'][:80]}...")

        try:
            result = query_ragservice(tc["question"])
        except urllib.error.URLError as e:
            print(f"  ERROR: Could not reach RAGService — {e}")
            print("  Skipping (service not running — ingest documents first)")
            continue

        answer = result.get("answer", "")
        is_relevant = result.get("is_relevant", False)
        score, matched = score_answer(answer, tc["required_keywords"])

        status = "PASS" if score >= PASS_THRESHOLD else "FAIL"
        if status == "FAIL":
            all_passed = False

        print(f"  Grounded in context : {is_relevant}")
        print(f"  Keyword score       : {score:.0%} ({len(matched)}/{len(tc['required_keywords'])} matched: {matched})")
        print(f"  Result              : {status}")
        if status == "FAIL":
            print(f"  Answer preview      : {answer[:200]}")

    print(f"\n{'=' * 50}")
    if all_passed:
        print("OVERALL: PASS — all test cases met quality threshold")
    else:
        print("OVERALL: FAIL — one or more test cases below quality threshold")
        print("Action: ingest more runbooks via POST /ingest, or review prompt in rag_pipeline.py")

    return all_passed


if __name__ == "__main__":
    passed = run_eval()
    sys.exit(0 if passed else 1)
