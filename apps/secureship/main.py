import time
import logging
import json
import os
from datetime import datetime

from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

try:
    import boto3
    from botocore.exceptions import ClientError
    DYNAMODB_AVAILABLE = True
except ImportError:
    DYNAMODB_AVAILABLE = False

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_obj = {
            "timestamp": datetime.utcnow().isoformat(),
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

# ── DynamoDB setup ────────────────────────────────────────────────────────────
DYNAMODB_TABLE = os.getenv("DYNAMODB_TABLE", "")

# Fallback data for local development (no DynamoDB)
_LOCAL_SHIPS = {
    "ship-001": {"ship_id": "ship-001", "name": "SS Mumbai", "status": "active", "cargo": "electronics"},
    "ship-002": {"ship_id": "ship-002", "name": "SS Delhi", "status": "docked", "cargo": "textiles"},
    "ship-003": {"ship_id": "ship-003", "name": "SS Chennai", "status": "transit", "cargo": "machinery"},
}

def get_dynamodb_table():
    if not DYNAMODB_AVAILABLE or not DYNAMODB_TABLE:
        return None
    return boto3.resource("dynamodb").Table(DYNAMODB_TABLE)


def db_list_ships() -> list:
    table = get_dynamodb_table()
    if table is None:
        return list(_LOCAL_SHIPS.values())
    try:
        result = table.scan()
        return result.get("Items", [])
    except ClientError as e:
        logger.error(json.dumps({"event": "dynamodb_error", "error": str(e)}))
        return list(_LOCAL_SHIPS.values())


def db_get_ship(ship_id: str) -> dict | None:
    table = get_dynamodb_table()
    if table is None:
        return _LOCAL_SHIPS.get(ship_id)
    try:
        result = table.get_item(Key={"ship_id": ship_id})
        return result.get("Item")
    except ClientError as e:
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


# ── Middleware ────────────────────────────────────────────────────────────────
@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    start_time = time.time()
    response = await call_next(request)
    duration = time.time() - start_time

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
        "timestamp": datetime.utcnow().isoformat(),
        "version": os.getenv('APP_VERSION', '1.0.0'),
        "storage": "dynamodb" if (DYNAMODB_AVAILABLE and DYNAMODB_TABLE) else "local"
    }

@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/api/ships")
async def list_ships():
    ships = db_list_ships()
    return {"ships": ships, "total": len(ships), "timestamp": datetime.utcnow().isoformat()}

@app.get("/api/ships/{ship_id}")
async def get_ship(ship_id: str):
    ship = db_get_ship(ship_id)
    if not ship:
        raise HTTPException(status_code=404, detail=f"Ship {ship_id} not found")
    return ship

@app.post("/api/ships")
async def create_ship(request: Request):
    body = await request.json()
    if "ship_id" not in body:
        raise HTTPException(status_code=400, detail="ship_id is required")
    ship = db_put_ship(body)
    logger.info("ship_created", extra={"ship_id": ship["ship_id"]})
    return {"message": "Ship created", "ship": ship, "timestamp": datetime.utcnow().isoformat()}

@app.get("/")
async def root():
    return {"service": "SecureShip API", "status": "running", "docs": "/docs"}
