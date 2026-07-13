# ADR-009: Groq (llama-3.1-8b-instant) Over OpenAI / Anthropic / Self-hosted

**Status:** Accepted  
**Date:** 2026-05-15

---

## Context

The LLM Alert Autopilot and RAGService both require an LLM inference endpoint. The choice of provider directly affects: diagnosis latency (time from alert to Slack message), cost, data privacy, and quality of the structured output.

Four realistic options were evaluated.

---

## Options Considered

### Option 1: OpenAI GPT-4o

- **Latency:** 2–8 seconds per call (heavily load-dependent)
- **Cost:** ~$0.005 per 1K input tokens + $0.015 per 1K output tokens. At 1 alert/5 minutes and ~500 tokens per diagnosis: ~$4/day → ~$120/month
- **Quality:** Excellent. Best at complex reasoning and structured output.
- **Rejected because:** At our alert volume the cost is manageable, but the latency is the dealbreaker. An on-call engineer waiting 8 seconds for a Slack diagnosis is 8 additional seconds of cognitive overload during an incident. The whole point of the autopilot is to compress the time between "alert fires" and "human knows the root cause." An 8-second LLM call adds to that window, not removes it.

### Option 2: Anthropic Claude Haiku

- **Latency:** 500ms–2 seconds
- **Cost:** ~$0.00025 per 1K input + $0.00125 per 1K output. At our volume: ~$0.40/day → ~$12/month
- **Quality:** Very good. Excellent instruction-following for structured format (DIAGNOSIS: / FIX: pattern).
- **Rejected because:** Claude Haiku is genuinely competitive. We would use it in production if Groq's free tier ran out. The reason we didn't start here: Groq has a free tier that covers our entire usage volume with better latency. Starting on a paid service when a free one is sufficient is poor FinOps.

### Option 3: Self-hosted (Ollama on EC2)

- **Latency:** 100–500ms on GPU; 15–60 seconds on CPU (t3.small)
- **Cost:** No API cost, but a GPU-capable EC2 (g4dn.xlarge) costs $375/month. Our entire AWS bill is $87/month.
- **Quality:** Depends on model. llama-3.1-8b is comparable to Groq's hosted version.
- **Rejected because:** 4× the infrastructure cost. And the t3.small instances we're running cannot run an 8B model — they have 2GB RAM, the model needs 16GB. Requires a dedicated GPU instance. This trades API cost for compute cost and adds another managed service to keep alive.

### Option 4: Groq (llama-3.1-8b-instant) ✅ Chosen

- **Latency:** 100–300ms per call. The "instant" in the model name refers to Groq's custom LPU (Language Processing Unit) hardware which achieves 8× lower latency than GPU inference for this model size.
- **Cost:** Free tier: 14,400 requests/day, 6,000 tokens/request. At 1 alert/5 min = 288 requests/day = 2% of the free tier.
- **Quality:** Sufficient for structured diagnosis. llama-3.1-8b reliably follows the `DIAGNOSIS: ... FIX: ...` output format with `temperature=0`. For complex multi-step reasoning it falls short of GPT-4, but structured extraction from logs at a fixed format is exactly the task this model handles well.
- **Privacy:** Logs are sent to Groq's API. For regulated industries (PCI-DSS, HIPAA) this is a blocker — self-hosted becomes mandatory regardless of cost.

---

## Decision

Use Groq with `llama-3.1-8b-instant` for both the LLM Alert Autopilot and as the generation backend for RAGService.

---

## Rationale

The latency difference is the deciding factor. 200ms vs 5 seconds changes the user experience of the autopilot from "near-instant" to "waiting for a response." For a tool meant to reduce MTTR, adding 5 seconds of LLM wait time to every alert is counterproductive.

Cost is a non-factor at this scale — the Groq free tier covers 50× our usage.

Model quality at the specific task (structured log extraction + diagnosis generation) is equivalent between llama-3.1-8b and GPT-4. The task is not "reason about complex ambiguity" — it is "extract root cause pattern from log lines and format output." Smaller models do this reliably.

---

## Consequences

**Positive:**
- Sub-300ms LLM inference — total autopilot pipeline (Loki query + LLM + Slack) stays under 3 seconds
- Zero cost at current alert volume
- Simple integration — Groq is OpenAI API-compatible, so migration to any other provider is a 2-line change

**Negative:**
- Logs are sent off-premise to Groq's API — incompatible with strict data residency requirements
- Groq free tier rate limits (14,400 req/day) — exceeded at 10+ alerts/minute sustained
- llama-3.1-8b can produce vague diagnoses when logs are empty — it cannot infer root cause from nothing

**Migration path:**
- Alert volume exceeds free tier → Groq paid tier ($0.10/M tokens, still cheaper than GPT-4)
- Data residency required → Ollama on a dedicated GPU instance (g4dn.xlarge)
- Diagnosis quality insufficient → swap model string to `claude-haiku-4-5` (Groq is OpenAI-compatible, Claude isn't, but the client swap is 5 lines)

---

## When this decision would change

If ObserveOps moved to a regulated environment (bank, hospital, government) where PII appears in logs, sending logs to Groq would violate data residency requirements. In that case: self-hosted Ollama on GPU, or a cloud provider with a BAA (Business Associate Agreement) and VPC-hosted LLM endpoint (AWS Bedrock, Azure OpenAI with private endpoint).

---

## The Interview Answer

"We chose Groq with llama-3.1-8b-instant over OpenAI GPT-4 for the alert autopilot. The latency was the deciding factor — Groq's LPU hardware gives 200ms inference vs 5 seconds for GPT-4. For a tool whose entire purpose is to compress incident diagnosis time, adding 5 seconds of LLM wait is counterproductive. The cost was also a factor — Groq's free tier covers 50× our alert volume, while GPT-4 would cost $120/month. The model quality trade-off is real but acceptable: llama-3.1-8b reliably produces structured output at temperature=0 for a fixed format. If we moved to a regulated environment where logs contain PII, we'd switch to self-hosted Ollama on a GPU instance — data residency would override the cost and latency advantages of the hosted API."
