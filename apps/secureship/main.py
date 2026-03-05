"""
SecureShip API - Main Application
==================================
This is a FastAPI application that simulates a real production API.
FastAPI is a modern Python web framework that automatically generates
API documentation and is fast enough for production use.
"""

import time
import logging
import json
import os
from datetime import datetime

# fastapi is the web framework - it handles HTTP requests and routing
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

# prometheus_client lets us expose metrics that Prometheus will scrape
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

# ─── Structured JSON Logging Setup ───────────────────────────────────────────
# In production, logs must be JSON so tools like Loki/ELK can parse them.
# Plain text logs like "ERROR something broke" are impossible to query at scale.

class JSONFormatter(logging.Formatter):
    """Formats every log line as a JSON object instead of plain text."""
    def format(self, record):
        log_object = {
            "timestamp": datetime.utcnow().isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        # If the log has extra fields attached, include them
        if hasattr(record, 'extra'):
            log_object.update(record.extra)
        return json.dumps(log_object)

# Set up the logger with our JSON formatter
handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger = logging.getLogger("secureship")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# ─── Prometheus Metrics Setup ─────────────────────────────────────────────────
# Metrics are the numbers Prometheus collects from your app.
# Counter: only goes up (total requests, total errors)
# Histogram: measures distribution (request latency, response size)
# Gauge: can go up and down (current active connections, memory usage)

# This counter tracks every HTTP request - we label by method, endpoint, status
REQUEST_COUNT = Counter(
    'http_requests_total',
    'Total number of HTTP requests',
    ['method', 'endpoint', 'status_code']
)

# This histogram measures how long each request takes
# Buckets define the latency ranges we care about (in seconds)
REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'HTTP request latency in seconds',
    ['method', 'endpoint'],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5]
)

# This gauge shows the app is running - useful for "is the app up?" checks
APP_INFO = Gauge(
    'app_info',
    'Application information',
    ['version', 'environment']
)

# Set the gauge to 1 (means "running") with version and env labels
APP_INFO.labels(
    version=os.getenv('APP_VERSION', '1.0.0'),
    environment=os.getenv('ENVIRONMENT', 'production')
).set(1)

# ─── FastAPI App Initialization ───────────────────────────────────────────────
# FastAPI() creates the application instance
app = FastAPI(
    title="SecureShip API",
    description="Production-grade API with full observability",
    version="1.0.0"
)

# ─── Middleware: Request Logging + Metrics ────────────────────────────────────
# Middleware runs on EVERY request before and after your route handlers.
# This is where we measure latency and log every request automatically.

@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    """
    This middleware:
    1. Records the start time
    2. Processes the request
    3. Calculates how long it took
    4. Records metrics and logs
    Every single request goes through this, automatically.
    """
    start_time = time.time()
    
    # call_next actually runs your route handler
    response = await call_next(request)
    
    # Calculate how long the request took
    duration = time.time() - start_time
    
    # Record the metric with labels
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.url.path,
        status_code=response.status_code
    ).inc()  # .inc() increments the counter by 1
    
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=request.url.path
    ).observe(duration)  # .observe() records the duration in the histogram
    
    # Log every request as structured JSON
    logger.info(
        "Request processed",
        extra={
            "method": request.method,
            "path": str(request.url.path),
            "status_code": response.status_code,
            "duration_ms": round(duration * 1000, 2),
            "client_ip": request.client.host if request.client else "unknown"
        }
    )
    
    return response

# ─── Routes ───────────────────────────────────────────────────────────────────

@app.get("/health")
async def health_check():
    """
    Health endpoint - this is what your ALB and Kubernetes use to check
    if the app is alive. Must return 200 when healthy.
    If this returns non-200, the load balancer stops sending traffic here.
    """
    return {
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat(),
        "version": os.getenv('APP_VERSION', '1.0.0'),
        "environment": os.getenv('ENVIRONMENT', 'production')
    }

@app.get("/metrics")
async def metrics():
    """
    Prometheus scrapes this endpoint every 15 seconds.
    It returns all our metrics in a specific text format Prometheus understands.
    generate_latest() converts our Python metric objects to that format.
    """
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST
    )

@app.get("/api/ships")
async def list_ships():
    """Main business endpoint - returns a list of ships."""
    logger.info("Listing all ships")
    return {
        "ships": [
            {"id": 1, "name": "SS Mumbai", "status": "active", "cargo": "electronics"},
            {"id": 2, "name": "SS Delhi", "status": "docked", "cargo": "textiles"},
            {"id": 3, "name": "SS Chennai", "status": "transit", "cargo": "machinery"},
        ],
        "total": 3,
        "timestamp": datetime.utcnow().isoformat()
    }

@app.get("/api/ships/{ship_id}")
async def get_ship(ship_id: int):
    """Get a specific ship by ID."""
    ships = {
        1: {"id": 1, "name": "SS Mumbai", "status": "active", "cargo": "electronics"},
        2: {"id": 2, "name": "SS Delhi", "status": "docked", "cargo": "textiles"},
        3: {"id": 3, "name": "SS Chennai", "status": "transit", "cargo": "machinery"},
    }
    if ship_id not in ships:
        logger.warning(f"Ship {ship_id} not found")
        return JSONResponse(
            status_code=404,
            content={"error": f"Ship {ship_id} not found"}
        )
    return ships[ship_id]

@app.post("/api/ships")
async def create_ship(request: Request):
    """Create a new ship entry."""
    body = await request.json()
    logger.info(f"Creating new ship: {body.get('name', 'unknown')}")
    return {
        "message": "Ship created successfully",
        "ship": body,
        "timestamp": datetime.utcnow().isoformat()
    }

@app.get("/")
async def root():
    """Root endpoint - useful for quick sanity checks."""
    return {
        "service": "SecureShip API",
        "status": "running",
        "docs": "/docs",
        "health": "/health",
        "metrics": "/metrics"
    }
