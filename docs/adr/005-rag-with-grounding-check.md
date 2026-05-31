# ADR-005: RAG Pipeline with Grounding Verification Instead of Raw LLM

**Status:** Accepted
**Date:** 2026-05-01

---

## Context

We needed an AI assistant that could answer questions about incidents, runbooks, and infrastructure. The simplest approach: call an LLM with the question and return whatever it says.

## Decision

Build a Retrieval-Augmented Generation (RAG) pipeline using FAISS for vector search, with an explicit grounding check that rejects answers not supported by retrieved context.

## Rationale

**The hallucination problem:**

Large language models generate plausible-sounding text, not necessarily accurate text. When asked "what do I do if ragservice is down?", a raw LLM might say:
- "Restart the Kubernetes pod" (we don't use Kubernetes in Docker Compose)
- "Check the health endpoint at port 8080" (wrong port — RAGService is on 8003)
- "Look at the systemd service logs" (we use Docker, not systemd for services)

We observed exactly this behavior today when the LLM had no context and suggested `systemctl start rag-service`.

An on-call engineer following hallucinated instructions at 3am wastes time, might make the incident worse, and loses trust in the system.

**The RAG solution:**

Instead of sending the question directly to the LLM, we:
1. Embed the question as a vector using all-MiniLM-L6-v2
2. Search FAISS for the most similar runbook chunks
3. Grade the relevance: if best cosine similarity < threshold, we have no useful context
4. If relevant context exists: send (question + context) to LLM, constrain it to only use that context
5. If no relevant context: return a clear "I don't have enough context" message instead of a hallucination

**The grounding threshold:**

FAISS returns L2 distances. For unit-norm embeddings, d² = 2*(1 - cosine_similarity).
- d² < 1.5 → cosine_similarity > 0.25 → meaningfully related to the domain
- d² ≥ 1.5 → cosine_similarity ≤ 0.25 → off-topic or unknown

We set 0.25 as the minimum cosine similarity because:
- Scores above 0.25 reliably indicate topical relevance
- Below 0.25, even "similar" chunks are probably noise from a different domain
- We'd rather say "I don't know" than give a confident wrong answer

**Why FAISS instead of a managed vector database:**

Options considered: Pinecone, Weaviate, ChromaDB, pgvector.

We chose FAISS because:
- Zero external dependencies — runs in the same container, no network calls
- No managed service cost (~$70/month for Pinecone starter)
- Fast enough for our scale (hundreds of runbook chunks)
- The `faiss-cpu` package is pure Python install — no infrastructure to manage

The tradeoff: FAISS is in-memory only. The index is lost on restart and must be re-ingested. We accept this and handle it with an auto-ingest step in deploy.sh. At scale, we would move to a persistent vector database.

**The LangGraph agent graph:**

We use LangGraph to model the RAG pipeline as a state machine:
```
START → retrieve → grade → [generate | no_context] → END
```

The conditional edge after `grade` is the grounding check. This makes the routing explicit, inspectable, and testable — unlike a chain where the routing logic is buried inside the LLM prompt.

## Consequences

**Positive:**
- LLM answers are grounded in actual runbooks
- Clear failure mode: "I don't have context" instead of hallucination
- RAGHighUngroundedRate alert monitors knowledge base health
- Explainability: every answer includes the source documents it was derived from

**Negative:**
- FAISS index is in-memory — lost on restart
- Quality depends entirely on what's been ingested
- The grounding threshold (0.25) is empirically set — may need tuning
- Higher latency than a raw LLM call (embedding + FAISS search + LLM call)

**Known limitation and mitigation:**

The in-memory FAISS store is the largest operational gap. The mitigation is the auto-ingest step in deploy.sh — every deploy automatically re-ingests all runbooks from `docs/runbooks/`. The system is empty for at most the seconds between container start and the first deploy completing.

## The Interview Answer

"We use RAG instead of a raw LLM because LLMs hallucinate, and hallucinated on-call instructions are dangerous. The key design decision was adding an explicit grounding check — if FAISS similarity is below our threshold, we return 'I don't have enough context' instead of letting the LLM make something up. We saw this matter directly: without runbook context, the LLM suggested systemctl and kubectl commands that don't apply to our Docker Compose setup. With grounding, it gives exact Docker Compose commands pulled from our runbooks. The RAGHighUngroundedRate alert monitors this — if more than 50% of queries are ungrounded, it means our knowledge base needs updating, which is a model quality signal separate from infrastructure health."
