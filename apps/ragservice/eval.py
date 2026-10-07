#!/usr/bin/env python3
"""
RAG Quality Evaluation Harness
-------------------------------
Runs 5 representative queries against a LIVE RAGService and scores each answer
for keyword coverage.

It needs a running service with documents ingested and a working LLM key, so it
is run against a deployed stack (or a local `make dev-up`), not in CI. The
deterministic part of answer quality - does retrieval find the right runbook,
does the grounding check reject off-topic questions - is covered by
tests/test_retrieval.py, which does run in CI.

Exit codes:
    0  every case was evaluated and met the threshold
    1  at least one evaluated case scored below the threshold
    2  nothing, or not everything, could be evaluated: NOT a pass

Usage:
    python eval.py                                 # service on localhost:8003
    RAGSERVICE_URL=http://host:8003 python eval.py
    RAGSERVICE_URL=http://host/ai python eval.py   # through nginx
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
        # BASE_URL is the service root: http://host:8003 directly, or http://host/ai
        # through nginx, which strips the /ai prefix. This used to append /ai/query
        # to a direct :8003 address, a path the service does not have.
        f"{BASE_URL.rstrip('/')}/query",
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


def run_eval() -> int:
    print(f"RAG Quality Evaluation — {BASE_URL}\n{'=' * 50}")
    all_passed = True
    evaluated = 0

    for tc in TEST_CASES:
        print(f"\n[{tc['name']}]")
        print(f"  Q: {tc['question'][:80]}...")

        try:
            result = query_ragservice(tc["question"])
        except urllib.error.URLError as e:
            print(f"  NOT EVALUATED: could not reach RAGService — {e}")
            continue
        evaluated += 1

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
    print(f"Evaluated {evaluated} of {len(TEST_CASES)} cases")
    # A run that evaluated nothing must never be reported as a pass. It used to:
    # unreachable cases were skipped, all_passed stayed True, and the harness
    # printed PASS having checked nothing.
    if evaluated == 0:
        print("OVERALL: NOT EVALUATED — no case could reach the service")
        return 2
    if not all_passed:
        print("OVERALL: FAIL — one or more test cases below quality threshold")
        print("Action: ingest more runbooks via POST /ingest, or review prompt in rag_pipeline.py")
        return 1
    if evaluated < len(TEST_CASES):
        print("OVERALL: INCOMPLETE — some cases could not be evaluated")
        return 2
    print("OVERALL: PASS — all test cases met quality threshold")
    return 0


if __name__ == "__main__":
    sys.exit(run_eval())
