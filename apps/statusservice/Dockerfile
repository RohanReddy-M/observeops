FROM python:3.11-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.11-slim AS runtime

# Non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app
COPY --from=builder /install /usr/local
COPY . .
RUN chown -R appuser:appuser /app

USER appuser
EXPOSE 8002

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8002/health')"

# gunicorn is a production-grade WSGI server for Flask
# 2 workers = handles 2 concurrent requests
CMD ["gunicorn", "--bind", "0.0.0.0:8002", "--workers", "2", "--timeout", "120", "main:app"]
