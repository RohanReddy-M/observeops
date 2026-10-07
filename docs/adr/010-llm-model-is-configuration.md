# ADR-010: The LLM Model Identifier Is Configuration, Not Code

**Status:** Accepted. Amends ADR-009 (the provider choice stands; the model named there is gone).
**Date:** 2026-10-07

---

## Context

ADR-009 chose Groq and named a model, `llama-3.1-8b-instant`. That string was written directly into two services. Its consequences section said that moving to another model was "a 2-line change".

In October 2026 a routine review ran the stack and sent it an alert. Every LLM call returned `404 model_not_found`: the provider had retired the model. Nobody had noticed, for three reasons that are each worth more than the outage itself:

1. **Nothing alerted.** The RAG service caught the exception, returned a polite "LLM unavailable" sentence with HTTP 200, and counted the request as a success. `LLMHighErrorRate` is computed from that counter, so it read zero. The autopilot logged an error and moved on; the plain alert still reached Slack through its own route, so the channel looked normal. Only the diagnosis was missing.
2. **Nothing tested it.** The RAG tests replace the whole pipeline with a mock. The step called "RAG quality gate" in CI ran against a service that was not running, skipped every case and printed PASS.
3. **The fix was not two lines.** It was a code change in two services and an image rebuild, and the obvious replacement did not work: `openai/gpt-oss-20b` is a reasoning model, and with the existing `max_tokens=350` it spent the whole budget on reasoning and returned the seven characters `DIAGNOS`.

## Decision

1. The model identifier comes from the environment (`GROQ_MODEL`), with a default in code. So does `GROQ_REASONING_EFFORT`.
2. An LLM response that is empty, or cut off by the token limit, is a failed call. It is counted and alerted on; it is never forwarded as an answer.
3. A failed LLM call is recorded as an error even when the user still receives a readable fallback. The service being polite to the caller must not make it dishonest to its own metrics.
4. A new alert, `AutopilotDiagnosisFailing`, fires on any diagnosis error. In normal operation there are none.

## Rationale

**A hosted model name is a dependency with a deprecation schedule you do not control.** We pin library versions and let Dependabot propose upgrades; a model id deserves at least the same treatment, and unlike a library it can stop existing while your pinned version is still "installed". Configuration is the cheapest place to absorb that: changing a model becomes an edit to `.env` and a restart, not a release.

**Graceful degradation and honest metrics are separate concerns.** Returning a fallback to the user was the right behaviour. Counting it as success was the bug. The rule now is that the response the user sees and the outcome the metric records are decided independently.

**Why `reasoning_effort` is a setting too.** It is the difference between a 0.5 s correct answer and a truncated one for the current default, and a different model may want a different value or none. It is accepted by the non-reasoning models as well, so "low" is a safe default.

## Alternatives considered

*Keep it in code and update when it breaks.* That is what we had. The cost was an unknown number of weeks with the headline feature dead.

*Query the provider's model list at startup and pick one.* Removes the stale-name failure but makes behaviour depend on whatever the provider lists that day. Rejected: an explicit setting plus an alert is easier to reason about.

*Self-host the model.* Removes the provider's schedule entirely. ADR-009's cost reasoning still holds (a GPU instance costs several times the rest of the stack).

## Consequences

**Positive**
- A model retirement is now a configuration change, and it pages within one alert evaluation instead of being discovered by accident.
- `llm_requests_total{status="error"}` and the RAG success-rate SLO mean what they say.

**Negative**
- One more setting that can be wrong. Mitigated by the default and by the alert.
- The default will go stale too. That is expected; the point is that it now fails loudly.

## When this decision would change

If the project needed reproducible model behaviour (for example, an evaluation set with expected answers), the model would be pinned deliberately and upgraded through the same evaluation, the way a library is.

## The Interview Answer

"I had hardcoded a hosted model name, and the provider retired it. The feature was dead and nothing told me, because the service returned a friendly fallback with a 200 and counted it as a success. So there were really three fixes: the model id became configuration, a failed call is recorded as a failure even when the user gets a fallback, and there is an alert on the diagnosis path itself. The part I would repeat to anyone is that graceful degradation for the user and honest metrics for the operator are two different decisions."
