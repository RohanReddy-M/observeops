# ─── Stage 1: Builder ─────────────────────────────────────────────────────────
# Install all Python dependencies here. We copy only the installed packages
# into the runtime stage, so the final image doesn't contain pip or build tools.
FROM python:3.11-slim AS builder

WORKDIR /build
COPY requirements.txt .

# System-wide install (NO --user flag).
# --user puts packages in /root/.local which appuser can't read.
# System-wide puts them in /usr/local/lib — readable by all users.
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir -r requirements.txt

# Pre-download the embedding model into /tmp/model_cache.
# /tmp is world-writable, so we can chown it in the runtime stage.
ENV SENTENCE_TRANSFORMERS_HOME=/tmp/model_cache
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"


# ─── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

WORKDIR /app

# Copy system-wide installed packages (accessible to all users)
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy pre-downloaded model into /app/.model_cache (will be owned by appuser)
COPY --from=builder /tmp/model_cache /app/.model_cache

COPY . .

# Non-root user: attacker who exploits the app gets a user with no sudo,
# no write access outside /app. Standard production hardening.
RUN useradd -m -u 1001 appuser && chown -R appuser:appuser /app
USER appuser

# Tell sentence-transformers and HuggingFace where the cached model lives
ENV SENTENCE_TRANSFORMERS_HOME=/app/.model_cache
ENV TRANSFORMERS_CACHE=/app/.model_cache

EXPOSE 8003

HEALTHCHECK --interval=30s --timeout=15s --start-period=60s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8003/health')"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8003", "--workers", "1"]
