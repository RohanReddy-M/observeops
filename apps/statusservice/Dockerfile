FROM python:3.11-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.11-slim AS runtime

# Non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app
COPY --from=builder /install /usr/local
COPY --chown=appuser:appuser . .

USER appuser
EXPOSE 8002

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8002/health')"

# gunicorn is a production-grade WSGI server for Flask
# 2 workers = handles 2 concurrent requests
# One worker process with threads, not two worker processes.
# prometheus_client keeps its counters in process memory. With two gunicorn workers
# and no multiprocess mode, each worker counted only its own requests and every
# scrape reached whichever worker answered, so the series jumped between two
# unrelated totals and rate() read each jump backwards as a counter reset. Threads
# share one process and therefore one set of metrics. /load is CPU-bound, but the
# interpreter still switches threads, so /health and /metrics keep answering.
CMD ["gunicorn", "--bind", "0.0.0.0:8002", "--workers", "1", "--threads", "4", "--timeout", "120", "main:app"]
