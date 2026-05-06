#!/usr/bin/env python3
"""
RAG Evaluation Harness
======================
Tests the RAGService with known questions and scores answer quality.

Why this exists:
  When you change the prompt template, swap the LLM, or add new documents,
  you need to know if the quality got better or worse. This script is the
  automated quality gate — it runs in CI and fails if scores drop below
  the threshold. This is called "model regression testing" in MLOps.

Usage:
  python scripts/eval_rag.py                         # test localhost
  python scripts/eval_rag.py --url http://1.2.3.4:8003
  python scripts/eval_rag.py --min-score 0.6         # stricter threshold

Exit codes:
  0 = all tests passed (suitable for CI gates)
  1 = quality below threshold or service unreachable
"""

import argparse
import json
import sys
import time

import httpx

# ─── Test Suite ───────────────────────────────────────────────────────────────
# Each test has:
#   question         : what a real user would ask
#   expected_keywords: words that MUST appear in a correct answer
#   description      : human label for the test report
#
# Keywords are chosen from the seed documents in main.py — if the RAG pipeline
# retrieves the right document and the LLM reads it, these words should appear.
TEST_CASES = [
    {
        "question": "What should I do when SecureShip goes down?",
        "expected_keywords": ["docker", "container", "logs", "compose"],
        "description": "ServiceDown runbook retrieval",
    },
    {
        "question": "How do I investigate a high error rate alert?",
        "expected_keywords": ["rollback", "loki", "error", "logs"],
        "description": "HighErrorRate runbook retrieval",
    },
    {
        "question": "What caused the February 2024 incident on StatusService?",
        "expected_keywords": ["failure_rate", "env", "rollback", "500"],
        "description": "Incident log retrieval",
    },
    {
        "question": "How do I free disk space when the disk is full?",
        "expected_keywords": ["docker", "prune", "df", "loki"],
        "description": "DiskSpaceCritical runbook retrieval",
    },
    {
        "question": "Describe the ObserveOps infrastructure architecture",
        "expected_keywords": ["ec2", "nginx", "private", "subnet"],
        "description": "Infrastructure overview retrieval",
    },
]


def score_answer(answer: str, keywords: list[str]) -> float:
    """Return fraction of expected keywords present in the answer."""
    answer_lower = answer.lower()
    hits = sum(1 for kw in keywords if kw.lower() in answer_lower)
    return hits / len(keywords)


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate RAGService answer quality")
    parser.add_argument("--url", default="http://localhost:8003", help="RAGService base URL")
    parser.add_argument("--min-score", type=float, default=0.5, help="Minimum average score to pass (0-1)")
    args = parser.parse_args()

    print(f"=== RAG Evaluation === {args.url}")
    print(f"Threshold: {args.min_score:.0%}\n")

    # ── Health check ─────────────────────────────────────────────────────────
    try:
        health = httpx.get(f"{args.url}/health", timeout=10)
        health.raise_for_status()
        print(f"✓ Service healthy | vector_store_ready={health.json().get('vector_store_ready')}\n")
    except Exception as exc:
        print(f"✗ Service unreachable: {exc}")
        sys.exit(1)

    # ── Run tests ────────────────────────────────────────────────────────────
    scores: list[float] = []

    for tc in TEST_CASES:
        start = time.time()
        try:
            resp = httpx.post(
                f"{args.url}/query",
                json={"question": tc["question"]},
                timeout=60,
            )
            duration = time.time() - start

            if resp.status_code != 200:
                print(f"✗ {tc['description']}: HTTP {resp.status_code}")
                scores.append(0.0)
                continue

            data = resp.json()
            answer = data.get("answer", "")
            grounded = data.get("is_relevant", False)
            score = score_answer(answer, tc["expected_keywords"])
            scores.append(score)

            status = "✓" if score >= args.min_score else "✗"
            print(f"{status} {tc['description']}  [{duration:.1f}s]")
            print(f"   Score   : {score:.0%}  |  Grounded: {grounded}")
            print(f"   Answer  : {answer[:120]}...")
            print()

        except Exception as exc:
            print(f"✗ {tc['description']}: error — {exc}")
            scores.append(0.0)

    # ── Summary ──────────────────────────────────────────────────────────────
    avg = sum(scores) / len(scores)
    passed = sum(1 for s in scores if s >= args.min_score)

    print("─" * 50)
    print(f"Tests passed : {passed}/{len(TEST_CASES)}")
    print(f"Average score: {avg:.0%}  (threshold: {args.min_score:.0%})")

    if avg < args.min_score:
        print("\n❌ EVALUATION FAILED — improve the knowledge base or prompt template")
        sys.exit(1)
    else:
        print("\n✅ EVALUATION PASSED")
        sys.exit(0)


if __name__ == "__main__":
    main()
