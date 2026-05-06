from prometheus_client import Counter, Histogram, Gauge

# How long each LLM call takes (in seconds).
# We label by model so if you swap from llama to gemma, charts split automatically.
llm_request_duration = Histogram(
    "llm_request_duration_seconds",
    "End-to-end latency of one LLM API call",
    ["model", "operation"],
    buckets=[0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0],
)

# Count of LLM calls, split by success / error.
# Alerting rule: if error rate > 10%, fire LLMHighErrorRate alert.
llm_requests_total = Counter(
    "llm_requests_total",
    "Total LLM API requests",
    ["model", "status"],
)

# Count RAG queries, labelled by whether the answer was grounded in context.
# Low grounded ratio means your vector store needs better documents.
rag_queries_total = Counter(
    "rag_queries_total",
    "Total queries through the RAG pipeline",
    ["grounded"],
)

# Distribution of how many documents each query retrieves.
# If consistently 0 relevant docs, your embedding model or query format is off.
rag_documents_retrieved = Histogram(
    "rag_documents_retrieved",
    "Number of documents retrieved per RAG query",
    buckets=[0, 1, 2, 3, 4, 5, 10],
)

# Current size of the FAISS vector store (so you can see it grow on Grafana).
vector_store_documents = Gauge(
    "vector_store_documents_total",
    "Number of document chunks currently in the FAISS vector store",
)
