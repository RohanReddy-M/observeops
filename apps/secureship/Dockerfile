# ─── Stage 1: Builder ─────────────────────────────────────────────────────────
# Multi-stage builds keep the final image small and secure.
# This stage installs dependencies. The next stage only copies what's needed.
# Why: build tools, pip cache, etc. don't need to be in your production image.
FROM python:3.11-slim AS builder

# Set working directory inside the container
WORKDIR /app

# Copy ONLY requirements first - before copying your app code.
# Why: Docker caches each layer. If you copy code first, any code change
# invalidates the pip install cache and reinstalls everything from scratch.
# This order means pip install is only re-run when requirements.txt changes.
COPY requirements.txt .

# Install dependencies into a specific directory we can copy later
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ─── Stage 2: Runtime ─────────────────────────────────────────────────────────
# Fresh slim image - no build tools, no pip cache, no cruft
FROM python:3.11-slim AS runtime

# Security: create a non-root user to run the application
# Why: if someone exploits your app, they get this limited user, not root
# In production, NEVER run containers as root
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Copy installed packages from the builder stage
COPY --from=builder /install /usr/local

# Copy application code
COPY . .

# Change ownership of app files to our non-root user
RUN chown -R appuser:appuser /app

# Switch to non-root user for all subsequent commands
USER appuser

# Document which port the app listens on (doesn't actually open the port)
# The actual port binding happens in docker run -p or docker-compose
EXPOSE 8001

# Health check: Docker will run this every 30s
# If it fails 3 times, Docker marks the container as unhealthy
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8001/health')"

# The command that runs when the container starts
# --host 0.0.0.0: listen on all interfaces (required inside containers)
# --port 8001: our app port
# --workers 2: handle 2 requests simultaneously
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001", "--workers", "2"]
