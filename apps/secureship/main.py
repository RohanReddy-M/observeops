import time
import logging
import json
import os
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, Request, Response, HTTPException, Security, Depends
from fastapi.responses import JSONResponse, HTMLResponse, RedirectResponse
from fastapi.security.api_key import APIKeyHeader
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource

_resource = Resource.create({"service.name": "secureship", "service.version": "1.0.0"})
_provider = TracerProvider(resource=_resource)
_otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=_otlp_endpoint, insecure=True)))
trace.set_tracer_provider(_provider)

try:
    import boto3
    from botocore.exceptions import ClientError
    DYNAMODB_AVAILABLE = True
except ImportError:
    DYNAMODB_AVAILABLE = False


class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_obj = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        if hasattr(record, 'extra'):
            log_obj.update(record.extra)
        return json.dumps(log_obj)


handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger = logging.getLogger("secureship")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

REQUEST_COUNT = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status_code']
)
REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'HTTP request latency',
    ['method', 'endpoint'],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5]
)
APP_INFO = Gauge('app_info', 'Application info', ['version', 'environment'])
APP_INFO.labels(
    version=os.getenv('APP_VERSION', '1.0.0'),
    environment=os.getenv('ENVIRONMENT', 'production')
).set(1)

app = FastAPI(title="SecureShip API", version="1.0.0")
FastAPIInstrumentor.instrument_app(app)

# ── Rate limiting ──────────────────────────────────────────────────────────────
# Rate-limit by API key so each caller gets its own independent bucket.
# Without this, one bad client can saturate the service and starve legitimate traffic.
# This is the application-layer defense. ALB + WAF handle the network layer in AWS.
def _rate_limit_key(request: Request) -> str:
    key = request.headers.get("X-API-Key")
    return key if key else (request.client.host if request.client else "unknown")

limiter = Limiter(key_func=_rate_limit_key)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# ── Auth ──────────────────────────────────────────────────────────────────────
# Set API_KEY env var to enable key-based auth. Empty = open mode (local dev).
API_KEY = os.getenv("API_KEY", "")
_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def verify_api_key(api_key: Optional[str] = Security(_api_key_header)):
    if not API_KEY:
        return  # Auth not configured — allow all (local development)
    if api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


# ── Pydantic models ───────────────────────────────────────────────────────────
class ShipCreate(BaseModel):
    ship_id: str = Field(..., min_length=1, max_length=64, pattern=r'^[a-zA-Z0-9-]+$')
    name: str = Field(..., min_length=1, max_length=128)
    status: str = Field(..., pattern=r'^(active|docked|transit)$')
    cargo: str = Field(..., min_length=1, max_length=256)


class ShipUpdate(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=128)
    status: Optional[str] = Field(None, pattern=r'^(active|docked|transit)$')
    cargo: Optional[str] = Field(None, min_length=1, max_length=256)


# ── DynamoDB setup ────────────────────────────────────────────────────────────
DYNAMODB_TABLE = os.getenv("DYNAMODB_TABLE", "")

_LOCAL_SHIPS = {
    "ship-001": {"ship_id": "ship-001", "name": "SS Mumbai", "status": "active", "cargo": "electronics"},
    "ship-002": {"ship_id": "ship-002", "name": "SS Delhi", "status": "docked", "cargo": "textiles"},
    "ship-003": {"ship_id": "ship-003", "name": "SS Chennai", "status": "transit", "cargo": "machinery"},
}


def get_dynamodb_table():
    if not DYNAMODB_AVAILABLE or not DYNAMODB_TABLE:
        return None
    region = os.getenv("AWS_DEFAULT_REGION", "ap-south-1")
    return boto3.resource("dynamodb", region_name=region).Table(DYNAMODB_TABLE)


def db_list_ships() -> list:
    table = get_dynamodb_table()
    if table is None:
        return list(_LOCAL_SHIPS.values())
    try:
        result = table.scan()
        return result.get("Items", [])
    except Exception as e:
        logger.error(json.dumps({"event": "dynamodb_error", "error": str(e)}))
        return list(_LOCAL_SHIPS.values())


def db_get_ship(ship_id: str) -> dict | None:
    table = get_dynamodb_table()
    if table is None:
        return _LOCAL_SHIPS.get(ship_id)
    try:
        result = table.get_item(Key={"ship_id": ship_id})
        return result.get("Item")
    except Exception as e:
        logger.error(json.dumps({"event": "dynamodb_error", "error": str(e)}))
        return _LOCAL_SHIPS.get(ship_id)


def db_put_ship(ship: dict) -> dict:
    table = get_dynamodb_table()
    if table is None:
        _LOCAL_SHIPS[ship["ship_id"]] = ship
        return ship
    try:
        table.put_item(Item=ship)
        return ship
    except ClientError as e:
        logger.error(json.dumps({"event": "dynamodb_error", "error": str(e)}))
        raise


def db_delete_ship(ship_id: str) -> bool:
    table = get_dynamodb_table()
    if table is None:
        if ship_id not in _LOCAL_SHIPS:
            return False
        del _LOCAL_SHIPS[ship_id]
        return True
    try:
        table.delete_item(Key={"ship_id": ship_id})
        return True
    except ClientError as e:
        logger.error(json.dumps({"event": "dynamodb_error", "error": str(e)}))
        raise


# ── Middleware ────────────────────────────────────────────────────────────────
@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())
    start_time = time.time()
    response = await call_next(request)
    duration = time.time() - start_time

    response.headers["X-Request-ID"] = request_id

    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.url.path,
        status_code=response.status_code
    ).inc()
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=request.url.path
    ).observe(duration)
    logger.info("request", extra={
        "request_id": request_id,
        "method": request.method,
        "path": str(request.url.path),
        "status_code": response.status_code,
        "duration_ms": round(duration * 1000, 2),
    })
    return response


# ── Routes ────────────────────────────────────────────────────────────────────
@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "version": os.getenv('APP_VERSION', '1.0.0'),
        "storage": "dynamodb" if (DYNAMODB_AVAILABLE and DYNAMODB_TABLE) else "local"
    }


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


# v1 API
@app.get("/api/v1/ships", dependencies=[Depends(verify_api_key)])
@limiter.limit("100/minute")
async def list_ships(
    request: Request,
    limit: int = 20,
    offset: int = 0,
    status: Optional[str] = None,
):
    """
    List ships with pagination.
    - limit: max records to return (1-100, default 20)
    - offset: records to skip for pagination (default 0)
    - status: filter by status (active|docked|transit)
    """
    if not 1 <= limit <= 100:
        raise HTTPException(status_code=400, detail="limit must be between 1 and 100")
    if offset < 0:
        raise HTTPException(status_code=400, detail="offset must be >= 0")

    all_ships = db_list_ships()

    if status:
        valid_statuses = {"active", "docked", "transit"}
        if status not in valid_statuses:
            raise HTTPException(status_code=400, detail=f"status must be one of {valid_statuses}")
        all_ships = [s for s in all_ships if s.get("status") == status]

    total = len(all_ships)
    page = all_ships[offset : offset + limit]

    return {
        "ships": page,
        "total": total,
        "limit": limit,
        "offset": offset,
        "has_more": (offset + limit) < total,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/v1/ships/{ship_id}", dependencies=[Depends(verify_api_key)])
@limiter.limit("100/minute")
async def get_ship(request: Request, ship_id: str):
    ship = db_get_ship(ship_id)
    if not ship:
        raise HTTPException(status_code=404, detail=f"Ship {ship_id} not found")
    return ship


@app.post("/api/v1/ships", dependencies=[Depends(verify_api_key)])
@limiter.limit("30/minute")
async def create_ship(request: Request, ship: ShipCreate):
    saved = db_put_ship(ship.model_dump())
    logger.info("ship_created", extra={"ship_id": saved["ship_id"]})
    return {"message": "Ship created", "ship": saved, "timestamp": datetime.now(timezone.utc).isoformat()}


@app.put("/api/v1/ships/{ship_id}", dependencies=[Depends(verify_api_key)])
@limiter.limit("30/minute")
async def update_ship(request: Request, ship_id: str, updates: ShipUpdate):
    existing = db_get_ship(ship_id)
    if not existing:
        raise HTTPException(status_code=404, detail=f"Ship {ship_id} not found")
    updated = {**existing, **{k: v for k, v in updates.model_dump().items() if v is not None}}
    saved = db_put_ship(updated)
    logger.info("ship_updated", extra={"ship_id": ship_id})
    return {"message": "Ship updated", "ship": saved, "timestamp": datetime.now(timezone.utc).isoformat()}


@app.delete("/api/v1/ships/{ship_id}", dependencies=[Depends(verify_api_key)])
@limiter.limit("30/minute")
async def delete_ship(request: Request, ship_id: str):
    existing = db_get_ship(ship_id)
    if not existing:
        raise HTTPException(status_code=404, detail=f"Ship {ship_id} not found")
    db_delete_ship(ship_id)
    logger.info("ship_deleted", extra={"ship_id": ship_id})
    return {"message": f"Ship {ship_id} deleted", "timestamp": datetime.now(timezone.utc).isoformat()}


# Backward-compatible redirects — old /api/ships/* → /api/v1/ships/*
@app.get("/api/ships", include_in_schema=False)
async def redirect_list_ships():
    return RedirectResponse(url="/api/v1/ships", status_code=301)


@app.get("/api/ships/{ship_id}", include_in_schema=False)
async def redirect_get_ship(ship_id: str):
    return RedirectResponse(url=f"/api/v1/ships/{ship_id}", status_code=301)


@app.post("/api/ships", include_in_schema=False)
async def redirect_create_ship():
    return RedirectResponse(url="/api/v1/ships", status_code=308)  # 308 preserves POST body


@app.get("/", response_class=HTMLResponse)
async def root():
    version = os.getenv('APP_VERSION', '1.0.0')
    environment = os.getenv('ENVIRONMENT', 'production')
    storage = "dynamodb" if (DYNAMODB_AVAILABLE and DYNAMODB_TABLE) else "local"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ObserveOps — SecureShip Platform</title>
  <style>
    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: #0d1117; color: #e6edf3; min-height: 100vh; padding: 48px 24px; }}
    .container {{ max-width: 860px; margin: 0 auto; }}
    h1 {{ font-size: 2rem; font-weight: 700; color: #58a6ff; margin-bottom: 4px; }}
    .subtitle {{ color: #8b949e; font-size: 1rem; margin-bottom: 40px; }}
    .badge {{ display: inline-block; background: #238636; color: #fff;
              font-size: 0.7rem; padding: 2px 10px; border-radius: 20px;
              vertical-align: middle; margin-left: 10px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
             gap: 16px; margin-bottom: 40px; }}
    .card {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px;
             padding: 20px; }}
    .card h3 {{ font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.05em;
                color: #8b949e; margin-bottom: 12px; }}
    .status-row {{ display: flex; justify-content: space-between; align-items: center;
                   padding: 6px 0; border-bottom: 1px solid #21262d; font-size: 0.9rem; }}
    .status-row:last-child {{ border-bottom: none; }}
    .dot {{ width: 8px; height: 8px; border-radius: 50%; background: #3fb950; display: inline-block; }}
    .links {{ display: flex; gap: 12px; flex-wrap: wrap; }}
    .link {{ display: inline-block; padding: 8px 18px; border-radius: 6px;
             text-decoration: none; font-size: 0.88rem; font-weight: 500;
             border: 1px solid #30363d; color: #e6edf3; background: #21262d; }}
    .link:hover {{ background: #30363d; }}
    .link.primary {{ background: #238636; border-color: #238636; }}
    .link.primary:hover {{ background: #2ea043; }}
    .arch {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px;
             padding: 20px; margin-bottom: 40px; }}
    .arch h3 {{ font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.05em;
                color: #8b949e; margin-bottom: 16px; }}
    pre {{ font-family: 'SF Mono', 'Consolas', monospace; font-size: 0.82rem;
           color: #8b949e; line-height: 1.6; overflow-x: auto; }}
    pre .hl {{ color: #58a6ff; }}
    pre .grn {{ color: #3fb950; }}
    .meta {{ color: #8b949e; font-size: 0.82rem; }}
  </style>
</head>
<body>
  <div class="container">
    <h1>ObserveOps <span class="badge">LIVE</span></h1>
    <p class="subtitle">Cloud-native shipment platform · AWS · Kubernetes · GitOps · AI incident response</p>

    <div class="grid">
      <div class="card">
        <h3>Services</h3>
        <div class="status-row"><span>SecureShip API</span><span><span class="dot"></span></span></div>
        <div class="status-row"><span>StatusService</span><span><span class="dot"></span></span></div>
        <div class="status-row"><span>RAGService (AI)</span><span><span class="dot"></span></span></div>
      </div>
      <div class="card">
        <h3>Infrastructure</h3>
        <div class="status-row"><span>Storage</span><span style="color:#3fb950">{storage}</span></div>
        <div class="status-row"><span>Environment</span><span style="color:#3fb950">{environment}</span></div>
        <div class="status-row"><span>Version</span><span style="color:#8b949e">{version}</span></div>
      </div>
      <div class="card">
        <h3>Observability</h3>
        <div class="status-row"><span>Prometheus</span><span><span class="dot"></span></span></div>
        <div class="status-row"><span>Grafana</span><span><span class="dot"></span></span></div>
        <div class="status-row"><span>Loki + Promtail</span><span><span class="dot"></span></span></div>
      </div>
    </div>

    <div class="arch">
      <h3>Architecture</h3>
      <pre>
  Internet → Route53 (secureship.click) → <span class="hl">ALB (HTTPS/443)</span>
                                                  │
              ┌─────────────────────────────────────┤
              │                                     │
      <span class="grn">EC2: App Server</span>                  <span class="grn">EC2: Observability</span>
      nginx (rate limiting)            Prometheus · Grafana
      secureship   :8001               Loki · AlertManager
      statusservice:8002                     │
      ragservice   :8003        alerts → <span class="hl">Lambda</span> (AI diagnosis)
              │                              └→ <span class="hl">SNS</span> → notifications
              └→ <span class="hl">DynamoDB</span> (ships table)

  CI/CD: GitHub Actions → ECR → SSM deploy → smoke tests → rollback
  GitOps: ArgoCD App of Apps → sync waves → K8s manifests
      </pre>
    </div>

    <div class="links" style="margin-bottom:40px">
      <a class="link primary" href="/docs">API Docs (Swagger)</a>
      <a class="link" href="/api/v1/ships">Ships API</a>
      <a class="link" href="/grafana/">Grafana Dashboards</a>
      <a class="link" href="/prometheus/">Prometheus</a>
      <a class="link" href="https://github.com/RohanReddy-M/observeops" target="_blank">GitHub</a>
    </div>

    <p class="meta">
      Terraform · GitHub Actions · Docker · Kubernetes · ArgoCD · Prometheus · Grafana · Loki ·
      Lambda · DynamoDB · FastAPI · Flask · LangGraph · FAISS · Groq
    </p>
  </div>
</body>
</html>"""
