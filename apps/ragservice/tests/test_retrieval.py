"""
Retrieval and grounding tests for the RAG pipeline, against the REAL embedding
model and the REAL runbooks. No LLM is called and no network key is needed.

Why this file exists. test_main.py replaces the whole RAGPipeline with a mock, so
it tests the HTTP plumbing and nothing about retrieval. The step that used to be
called a "RAG quality gate" in CI ran eval.py against a service that was not
there, skipped every case and printed PASS. So the part of this service that is
actually interesting - does it find the right runbook, and does it refuse to
answer when it has nothing relevant - had no test at all.

What can be tested deterministically:
  - retrieval: for a question about X, is the runbook for X among the chunks
    handed to the LLM?
  - grounding: are unrelated questions rejected BEFORE any LLM call is made?
  - failure visibility: when the LLM call fails, does the result say so?

What cannot, and is not attempted here: the wording of the LLM's answer. That
is evaluated against a live deployment by eval.py.

The numbers these tests pin were measured on this corpus (9 runbooks, 89 chunks):
on-topic questions have a best squared-L2 distance of 0.77 to 1.24, unrelated ones
1.69 to 1.92. The relevance threshold of 1.5 sits in the gap between them.
"""
import glob
import os
import sys
import tempfile

import pytest

# ChatGroq needs a key to be constructed. No request is ever sent in this file.
os.environ.setdefault("GROQ_API_KEY", "not-used-in-tests")
# The pipeline's default model cache is /app/.model_cache (the container path).
# Outside the container, download the 80 MB embedding model somewhere writable.
os.environ.setdefault("SENTENCE_TRANSFORMERS_HOME", os.path.join(tempfile.gettempdir(), "st-model-cache"))

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
RUNBOOKS = os.path.abspath(os.path.join(HERE, "..", "..", "..", "docs", "runbooks"))

rag_pipeline = pytest.importorskip("rag_pipeline")

ON_TOPIC = [
    ("The ServiceDown alert fired for secureship. What steps should I take?", "service-down.md"),
    ("CPU usage is above 80 percent on the app server, how do I investigate?", "high-cpu.md"),
    ("The disk is almost full, what can I safely clean up?", "disk-space-low.md"),
    ("p99 latency is over two seconds, where do I look first?", "high-latency.md"),
    ("Error rate is 15 percent, what should I check?", "high-error-rate.md"),
    ("Memory available is under 10 percent, what do I do?", "high-memory.md"),
    ("Loki is down and logs are not being stored", "loki-down.md"),
    ("LLM calls are failing with errors, what could be wrong?", "llm-high-error-rate.md"),
    ("Most answers are not grounded in context, why?", "rag-high-ungrounded-rate.md"),
]

OFF_TOPIC = [
    "What is the best recipe for chocolate cake?",
    "Who won the football world cup in 2018?",
    "Explain the plot of a romantic movie",
    "What is the capital of France?",
    "How do I bake sourdough bread at home?",
]

RELEVANCE_THRESHOLD = 1.5   # must match RAGPipeline._grade_relevance


def _empty_state(question):
    return {"query": question, "documents": [], "scores": [], "generation": "",
            "is_relevant": False, "llm_called": False, "llm_ok": True}


@pytest.fixture(scope="module")
def pipeline():
    files = sorted(glob.glob(os.path.join(RUNBOOKS, "*.md")))
    assert len(files) >= 9, f"expected the runbooks in {RUNBOOKS}, found {len(files)}"
    p = rag_pipeline.RAGPipeline()
    texts = [open(f, encoding="utf-8").read() for f in files]
    metas = [{"source": os.path.basename(f), "type": "runbook"} for f in files]
    chunks = p.ingest(texts, metas)
    assert chunks > len(files), "every runbook should split into several chunks"
    return p


# ── Retrieval ─────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("question,expected", ON_TOPIC)
def test_the_right_runbook_reaches_the_llm(pipeline, question, expected):
    """The runbook that answers the question is among the 4 chunks retrieved."""
    state = pipeline._retrieve(_empty_state(question))
    sources = [d.metadata.get("source") for d in state["documents"]]
    assert expected in sources, f"{expected} not retrieved for {question!r}; got {sources}"


def test_most_questions_rank_the_right_runbook_first(pipeline):
    """Measured: 8 of 9 at rank 1. Allow one more to slip before failing."""
    first = 0
    for question, expected in ON_TOPIC:
        state = pipeline._retrieve(_empty_state(question))
        first += state["documents"][0].metadata.get("source") == expected
    assert first >= 7, f"only {first} of {len(ON_TOPIC)} questions ranked the right runbook first"


# ── Grounding: the anti-hallucination check ───────────────────────────────────

@pytest.mark.parametrize("question,_expected", ON_TOPIC)
def test_on_topic_questions_are_graded_relevant(pipeline, question, _expected):
    state = pipeline._grade_relevance(pipeline._retrieve(_empty_state(question)))
    assert state["is_relevant"] is True
    assert pipeline._route(state) == "generate"


@pytest.mark.parametrize("question", OFF_TOPIC)
def test_unrelated_questions_are_rejected(pipeline, question):
    state = pipeline._grade_relevance(pipeline._retrieve(_empty_state(question)))
    assert state["is_relevant"] is False
    assert pipeline._route(state) == "no_context"


def test_threshold_sits_in_the_gap_between_related_and_unrelated(pipeline):
    """If this fails the threshold is no longer separating the two populations.

    That happens when the embedding model, the chunking or the corpus changes, and
    it is exactly the regression a quality gate should catch: either unrelated
    questions start reaching the LLM, or real ones start being refused.
    """
    related = [min(pipeline._retrieve(_empty_state(q))["scores"]) for q, _ in ON_TOPIC]
    unrelated = [min(pipeline._retrieve(_empty_state(q))["scores"]) for q in OFF_TOPIC]
    assert max(related) < RELEVANCE_THRESHOLD < min(unrelated), (
        f"related best-distances up to {max(related):.3f}, unrelated from {min(unrelated):.3f}; "
        f"threshold {RELEVANCE_THRESHOLD} must lie strictly between them"
    )


def test_an_unrelated_question_never_calls_the_llm(pipeline, monkeypatch):
    def must_not_be_called(*args, **kwargs):
        raise AssertionError("the LLM was called for a question the grounding check should have rejected")

    monkeypatch.setattr(pipeline, "_call_llm", must_not_be_called)
    result = pipeline.query("What is the best recipe for chocolate cake?")
    assert result["is_relevant"] is False
    assert result["llm_called"] is False
    assert "don't have enough context" in result["answer"]


# ── The LLM call: success and visible failure ─────────────────────────────────

def test_a_grounded_question_calls_the_llm_with_the_retrieved_context(pipeline, monkeypatch):
    seen = {}

    def fake_llm(prompt, context, query):
        seen["context"], seen["query"] = context, query
        return "restart the container"

    monkeypatch.setattr(pipeline, "_call_llm", fake_llm)
    result = pipeline.query("The disk is almost full, what can I safely clean up?")
    assert result["answer"] == "restart the container"
    assert result["llm_called"] is True and result["llm_ok"] is True
    assert "disk" in seen["context"].lower(), "the retrieved runbook text should be in the prompt context"
    assert len(result["sources"]) == 4


def test_a_failed_llm_call_is_reported_as_a_failure(pipeline, monkeypatch):
    """The user still gets a readable answer, but the result must not look like a success.

    Before this flag existed a dead LLM produced normal-looking 200 responses, the
    error counter stayed at zero and the LLM error-rate alert could never fire.
    """
    def broken_llm(prompt, context, query):
        raise RuntimeError("model_not_found")

    monkeypatch.setattr(pipeline, "_call_llm", broken_llm)
    result = pipeline.query("Loki is down and logs are not being stored")
    assert result["llm_called"] is True
    assert result["llm_ok"] is False
    assert "unavailable" in result["answer"].lower()
