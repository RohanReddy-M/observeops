from __future__ import annotations

import os
from typing import List, Literal, TypedDict

from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.embeddings import HuggingFaceEmbeddings
from langchain_community.vectorstores import FAISS
from langchain_core.documents import Document
from langchain_core.output_parsers import StrOutputParser
from langchain_core.prompts import ChatPromptTemplate
from langchain_groq import ChatGroq
from langgraph.graph import END, START, StateGraph


# ── LangGraph requires a TypedDict that describes the state flowing through
#    the graph. Every node receives this dict and returns an updated copy.
class GraphState(TypedDict):
    query: str
    documents: List[Document]
    scores: List[float]   # FAISS L2 distances — lower means more similar
    generation: str
    is_relevant: bool


class RAGPipeline:
    """
    Retrieval-Augmented Generation pipeline backed by:
      - FAISS        : fast local vector store (no network, no cost)
      - all-MiniLM   : free HuggingFace embedding model (~80 MB, CPU-only)
      - Groq/Llama   : free hosted LLM for generation
      - LangGraph    : stateful agent graph with conditional routing
    """

    def __init__(self) -> None:
        # HuggingFaceEmbeddings downloads the model once and caches it.
        # all-MiniLM-L6-v2 is 80 MB, fast on CPU, good enough for DevOps docs.
        self.embeddings = HuggingFaceEmbeddings(
            model_name="all-MiniLM-L6-v2",
            cache_folder=os.getenv("SENTENCE_TRANSFORMERS_HOME", "/app/.model_cache"),
        )
        self.vector_store: FAISS | None = None

        # llama-3.1-8b-instant: free on Groq, ~200 tokens/sec, good reasoning
        self.llm = ChatGroq(
            model="llama-3.1-8b-instant",
            temperature=0,
            api_key=os.getenv("GROQ_API_KEY"),
        )
        self.graph = self._build_graph()

    # ── Ingestion ─────────────────────────────────────────────────────────────

    def ingest(self, texts: List[str], metadatas: List[dict] | None = None) -> int:
        """
        Split texts into chunks, embed them, store in FAISS.
        Returns the number of chunks created (not the number of input texts).
        """
        splitter = RecursiveCharacterTextSplitter(
            chunk_size=500,   # characters per chunk
            chunk_overlap=50, # overlap so a sentence split across chunks isn't lost
        )
        docs = splitter.create_documents(
            texts, metadatas=metadatas or [{}] * len(texts)
        )
        if self.vector_store is None:
            # First ingest: create the store from scratch
            self.vector_store = FAISS.from_documents(docs, self.embeddings)
        else:
            # Subsequent ingests: add to existing store
            self.vector_store.add_documents(docs)
        return len(docs)

    # ── Graph Nodes ───────────────────────────────────────────────────────────
    # Each node is a pure function: takes GraphState, returns updated GraphState.

    def _retrieve(self, state: GraphState) -> GraphState:
        """Query FAISS for the 4 most similar chunks, keeping the L2 distances."""
        results = self.vector_store.similarity_search_with_score(state["query"], k=4)
        docs = [doc for doc, _ in results]
        scores = [float(score) for _, score in results]
        return {**state, "documents": docs, "scores": scores}

    def _grade_relevance(self, state: GraphState) -> GraphState:
        """
        Grade relevance by FAISS squared-L2 distance (IndexFlatL2 returns d²).
        For unit-norm embeddings: d² = 2*(1 - cosine_sim), range [0, 4].
        d² < 1.5  →  cosine_sim > 0.25  →  meaningfully related to the domain.
        d² ≥ 1.5  →  cosine_sim ≤ 0.25  →  off-topic, fallback to no_context.
        """
        scores = state.get("scores", [])
        is_relevant = bool(scores and min(scores) < 1.5)
        return {**state, "is_relevant": is_relevant}

    def _route(self, state: GraphState) -> Literal["generate", "no_context"]:
        """Conditional edge: branch based on relevance grade."""
        return "generate" if state["is_relevant"] else "no_context"

    def _generate(self, state: GraphState) -> GraphState:
        """Call the LLM with the retrieved context to produce an answer."""
        context = "\n\n---\n\n".join(d.page_content for d in state["documents"])
        prompt = ChatPromptTemplate.from_messages([
            (
                "system",
                "You are an expert DevOps engineer for the ObserveOps platform. "
                "Answer questions using ONLY the provided context about infrastructure, "
                "incidents, and runbooks. Be concise and actionable. "
                "If you reference a shell command, include it exactly.",
            ),
            ("human", "Context:\n{context}\n\nQuestion: {query}"),
        ])
        answer = (prompt | self.llm | StrOutputParser()).invoke(
            {"context": context, "query": state["query"]}
        )
        return {**state, "generation": answer}

    def _no_context(self, state: GraphState) -> GraphState:
        """Fallback node: tell the user we lack context rather than hallucinate."""
        return {
            **state,
            "generation": (
                "I don't have enough context in my knowledge base to answer this. "
                "Use POST /ingest to add relevant runbooks or incident logs first."
            ),
        }

    # ── Graph Assembly ────────────────────────────────────────────────────────

    def _build_graph(self):
        """
        Graph topology:
          START → retrieve → grade → [generate | no_context] → END

        The conditional edge after 'grade' is what makes this an agent rather
        than a simple chain — it can take different paths based on runtime state.
        """
        g = StateGraph(GraphState)

        g.add_node("retrieve", self._retrieve)
        g.add_node("grade", self._grade_relevance)
        g.add_node("generate", self._generate)
        g.add_node("no_context", self._no_context)

        g.add_edge(START, "retrieve")
        g.add_edge("retrieve", "grade")
        g.add_conditional_edges(
            "grade",
            self._route,
            {"generate": "generate", "no_context": "no_context"},
        )
        g.add_edge("generate", END)
        g.add_edge("no_context", END)

        return g.compile()

    # ── Public API ────────────────────────────────────────────────────────────

    def query(self, question: str) -> dict:
        if self.vector_store is None:
            raise ValueError("No documents ingested. POST to /ingest first.")

        result = self.graph.invoke(
            {"query": question, "documents": [], "scores": [], "generation": "", "is_relevant": False}
        )
        return {
            "answer": result["generation"],
            "is_relevant": result["is_relevant"],
            # Truncate source content so the API response stays readable
            "sources": [
                {"content": d.page_content[:200], "metadata": d.metadata}
                for d in result["documents"]
            ],
        }
