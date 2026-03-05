"""
StatusService - System Status + Load Simulation Service
=========================================================
This second microservice exists for a specific DevOps learning purpose:
- It lets us simulate CPU load (for autoscaling demo)
- It lets us simulate failures (for incident response practice)
- It gives us TWO services to monitor, route, and manage
  (one service isn't enough to demonstrate service routing or multi-service monitoring)
"""

import time
import os
import random
import logging
import json
import hashlib
from datetime import datetime
from flask import Flask, jsonify, request, Response
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

# ─── Structured JSON Logging ──────────────────────────────────────────────────
class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "timestamp": datetime.utcnow().isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "service": "statusservice"
        })

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger = logging.getLogger("statusservice")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# ─── Flask App ────────────────────────────────────────────────────────────────
# Flask is simpler than FastAPI - good for small services
app = Flask(__name__)

# ─── Prometheus Metrics ───────────────────────────────────────────────────────
REQUEST_COUNT = Counter('status_requests_total', 'Total requests', ['endpoint', 'status'])
REQUEST_LATENCY = Histogram('status_request_duration_seconds', 'Request latency', ['endpoint'])
FAILURE_RATE = Gauge('status_configured_failure_rate', 'Current configured failure rate')

# ─── Routes ───────────────────────────────────────────────────────────────────

@app.route('/health')
def health():
    """
    Health check endpoint.
    ALB health checks hit this. If this returns non-200, 
    the ALB stops sending traffic to this instance.
    """
    return jsonify({
        "status": "healthy",
        "service": "statusservice",
        "timestamp": datetime.utcnow().isoformat()
    }), 200

@app.route('/metrics')
def metrics():
    """Prometheus scrapes this endpoint every 15 seconds."""
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

@app.route('/status')
def status():
    """
    Returns system status information.
    In a real company this might aggregate health from multiple services.
    """
    REQUEST_COUNT.labels(endpoint='/status', status='200').inc()
    
    return jsonify({
        "services": {
            "secureship": "healthy",
            "statusservice": "healthy",
            "prometheus": "healthy",
            "grafana": "healthy"
        },
        "timestamp": datetime.utcnow().isoformat(),
        "uptime_seconds": time.time() - app.start_time
    })

@app.route('/load', methods=['POST'])
def generate_load():
    """
    CPU load generator - used for autoscaling simulation.
    
    Usage: POST /load?duration=30
    This will spike CPU for 30 seconds.
    
    Why this exists: In the real world, CPU spikes happen due to:
    - Traffic surges
    - Inefficient database queries
    - Memory leaks causing GC pressure
    - Background jobs running during peak hours
    
    We simulate this to test our alerting and demonstrate scaling behavior.
    """
    duration = int(request.args.get('duration', 10))
    duration = min(duration, 120)  # Max 2 minutes to prevent runaway load
    
    logger.info(f"Starting CPU load generation for {duration} seconds")
    
    start = time.time()
    iterations = 0
    
    # CPU-bound work: calculating hashes repeatedly
    # This is intentionally inefficient to spike CPU
    while time.time() - start < duration:
        # sha256 is CPU-intensive - good for load simulation
        hashlib.sha256(str(random.random()).encode()).hexdigest()
        iterations += 1
    
    logger.info(f"Load generation complete: {iterations} iterations in {duration}s")
    REQUEST_COUNT.labels(endpoint='/load', status='200').inc()
    
    return jsonify({
        "message": f"Load generated for {duration} seconds",
        "iterations": iterations,
        "timestamp": datetime.utcnow().isoformat()
    })

@app.route('/fail')
def simulate_failure():
    """
    Failure simulator - returns errors based on FAILURE_RATE env variable.
    
    Usage: Set FAILURE_RATE=0.5 to get 50% error rate
    
    Why this exists: We use this to:
    1. Test that our error rate alerts fire correctly
    2. Test that our Grafana dashboard shows the spike
    3. Practice incident response (find the cause, fix it, verify recovery)
    
    In production, failures happen because of:
    - Downstream service timeouts
    - Database connection exhaustion  
    - Memory pressure causing slow responses
    - Bad deployments introducing bugs
    """
    # Read failure rate from environment variable (default 0 = no failures)
    failure_rate = float(os.getenv('FAILURE_RATE', '0'))
    FAILURE_RATE.set(failure_rate)
    
    if random.random() < failure_rate:
        logger.error(f"Simulated failure triggered (rate={failure_rate})")
        REQUEST_COUNT.labels(endpoint='/fail', status='500').inc()
        return jsonify({"error": "Simulated service failure", "rate": failure_rate}), 500
    
    REQUEST_COUNT.labels(endpoint='/fail', status='200').inc()
    return jsonify({
        "message": "Request succeeded",
        "failure_rate": failure_rate,
        "timestamp": datetime.utcnow().isoformat()
    })

@app.route('/')
def root():
    return jsonify({
        "service": "StatusService",
        "endpoints": ["/health", "/metrics", "/status", "/load", "/fail"]
    })

if __name__ == '__main__':
    app.start_time = time.time()
    app.run(host='0.0.0.0', port=8002)
