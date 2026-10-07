import hashlib
import hmac
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
# OTEL_SDK_DISABLED is the spec-defined kill switch. Honour it so tests and local
# runs don't sit in an exporter retry loop against a collector that isn't there.
if os.getenv("OTEL_SDK_DISABLED", "").lower() not in ("true", "1", "yes"):
    _otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
    _provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=_otlp_endpoint, insecure=True)))
trace.set_tracer_provider(_provider)

try:
    import boto3
    from boto3.dynamodb.conditions import Attr
    from botocore.config import Config as BotoConfig
    DYNAMODB_AVAILABLE = True
except ImportError:
    DYNAMODB_AVAILABLE = False


# Attributes present on every LogRecord. Anything outside this set was passed by
# us via `extra=` and is the structured payload we actually want to emit.
_RESERVED_LOG_ATTRS = set(
    logging.LogRecord("", 0, "", 0, "", None, None).__dict__.keys()
) | {"asctime", "message", "taskName"}


class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_obj = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        # logging merges `extra={...}` into the record's __dict__ as top-level
        # attributes — there is no record.extra — so read them back off the record.
        for key, value in record.__dict__.items():
            if key not in _RESERVED_LOG_ATTRS and not key.startswith("_"):
                log_obj[key] = value
        if record.exc_info:
            log_obj["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_obj, default=str)


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
#
# Behind nginx or an ALB, request.client.host is the *proxy's* address, so every
# unauthenticated caller would share one bucket and the limit would be useless.
#
# Which header to trust matters. X-Forwarded-For is a list that each proxy APPENDS
# to, so its leftmost entry is whatever the client chose to send: keying on it
# would let anyone dodge the limit by inventing a new value per request. X-Real-IP
# is different: our nginx SETS it (overwriting anything the client sent) to the
# address it resolved by walking X-Forwarded-For from the right past trusted
# proxies only. So we use X-Real-IP, and fall back to the rightmost X-Forwarded-For
# entry, which is the hop that reached our own proxy. Both are meaningful only
# behind a proxy we control, hence TRUST_PROXY.
TRUST_PROXY = os.getenv("TRUST_PROXY", "true").lower() in ("true", "1", "yes")


def _rate_limit_key(request: Request) -> str:
    # Only the REAL key identifies a caller. This used to return whatever was in
    # the X-API-Key header, valid or not, so a client could give itself a fresh
    # rate-limit bucket on every request simply by sending a different made-up key.
    # The bucket name is a hash, so the key itself never lands in limiter storage.
    key = request.headers.get("X-API-Key")
    if key and API_KEY and hmac.compare_digest(key.encode(), API_KEY.encode()):
        return "key:" + hashlib.sha256(key.encode()).hexdigest()[:16]
    if TRUST_PROXY:
        real_ip = request.headers.get("X-Real-IP")
        if real_ip:
            return real_ip.strip()
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[-1].strip()
    return request.client.host if request.client else "unknown"

limiter = Limiter(key_func=_rate_limit_key)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# ── Auth ──────────────────────────────────────────────────────────────────────
# Set API_KEY env var to enable key-based auth. Empty = open mode (local dev).
API_KEY = os.getenv("API_KEY", "")
_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

# Fail closed, not open. Previously a missing API_KEY silently disabled auth, so
# one unset variable in a deploy would expose every endpoint with no signal at
# all. Auth is mandatory whenever a real datastore is attached, or when asked for
# explicitly; otherwise we stay open for local development but say so loudly.
REQUIRE_API_KEY = (
    os.getenv("REQUIRE_API_KEY", "").lower() in ("true", "1", "yes")
    or bool(os.getenv("DYNAMODB_TABLE", ""))
)

if REQUIRE_API_KEY and not API_KEY:
    raise RuntimeError(
        "API_KEY is required (REQUIRE_API_KEY is set, or DYNAMODB_TABLE is configured) "
        "but is empty. Refusing to start rather than serving unauthenticated."
    )
if not API_KEY:
    logger.warning(
        "auth_disabled",
        extra={"reason": "API_KEY not set", "mode": "local-development"},
    )


async def verify_api_key(api_key: Optional[str] = Security(_api_key_header)):
    if not API_KEY:
        return  # Auth not configured — local development only; see REQUIRE_API_KEY
    # compare_digest takes the same time whether the first character is wrong or
    # the last, so response timing does not reveal how much of a guess was right.
    if not api_key or not hmac.compare_digest(api_key.encode(), API_KEY.encode()):
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


# botocore's defaults are a 60 s connect timeout, a 60 s read timeout and several
# retries: one unreachable endpoint can hold a request for minutes. A caller has
# given up long before that, and every request stuck waiting occupies a worker
# thread. These bound a datastore call to a few seconds in the worst case, after
# which the caller gets a 503 it can retry.
_BOTO_CONFIG = None
_TABLE = None


def get_dynamodb_table():
    """The DynamoDB table, or None when running on the local sample data."""
    global _BOTO_CONFIG, _TABLE
    if not DYNAMODB_AVAILABLE or not DYNAMODB_TABLE:
        return None
    if _TABLE is None:      # built once; the resource object is safe to reuse
        _BOTO_CONFIG = BotoConfig(
            connect_timeout=2,
            read_timeout=3,
            retries={"max_attempts": 2, "mode": "standard"},
        )
        region = os.getenv("AWS_DEFAULT_REGION", "ap-south-1")
        _TABLE = boto3.resource("dynamodb", region_name=region, config=_BOTO_CONFIG).Table(DYNAMODB_TABLE)
    return _TABLE


# A single scan() returns at most 1 MB and reports LastEvaluatedKey when there is
# more. The previous code ignored that, so results were silently truncated once the
# table outgrew one page — a wrong answer returned as a success. We now follow the
# cursor, with a hard page cap so one request cannot read an unbounded table.
#
# scan() is still O(table): it reads every item and the filter is applied after the
# read, so you pay for all of it. The correct long-term fix is a global secondary
# index on `status` and a Query, which this cap is a stopgap for, not a substitute.
MAX_SCAN_PAGES = int(os.getenv("MAX_SCAN_PAGES", "20"))


class DataStoreUnavailable(Exception):
    """Raised when the datastore is configured but unreachable."""


def db_list_ships(status: Optional[str] = None) -> list:
    table = get_dynamodb_table()
    if table is None:
        items = list(_LOCAL_SHIPS.values())
        return [s for s in items if s.get("status") == status] if status else items
    kwargs = {}
    if status:
        kwargs["FilterExpression"] = Attr("status").eq(status)
    items, pages = [], 0
    try:
        while True:
            result = table.scan(**kwargs)
            items.extend(result.get("Items", []))
            pages += 1
            last_key = result.get("LastEvaluatedKey")
            if not last_key:
                break
            if pages >= MAX_SCAN_PAGES:
                logger.warning("scan_page_cap_reached", extra={
                    "pages": pages, "returned": len(items),
                    "detail": "result is incomplete; add a GSI and Query instead",
                })
                break
            kwargs["ExclusiveStartKey"] = last_key
        return items
    except Exception as e:
        # Do NOT fall back to the local sample data. Returning fabricated rows with
        # a 200 is worse than failing: every caller downstream believes it is real.
        logger.error("dynamodb_error", extra={"operation": "scan", "error": str(e)})
        raise DataStoreUnavailable(str(e)) from e


def db_get_ship(ship_id: str) -> dict | None:
    table = get_dynamodb_table()
    if table is None:
        return _LOCAL_SHIPS.get(ship_id)
    try:
        result = table.get_item(Key={"ship_id": ship_id})
        return result.get("Item")
    except Exception as e:
        logger.error("dynamodb_error", extra={"operation": "get_item", "error": str(e)})
        raise DataStoreUnavailable(str(e)) from e


def db_put_ship(ship: dict) -> dict:
    table = get_dynamodb_table()
    if table is None:
        _LOCAL_SHIPS[ship["ship_id"]] = ship
        return ship
    try:
        table.put_item(Item=ship)
        return ship
    # Exception, as in the read paths, not only botocore's ClientError: missing
    # credentials and unreachable endpoints raise other types, and those surfaced
    # as a bare 500 on writes while the same fault on a read was a clean 503.
    except Exception as e:
        logger.error("dynamodb_error", extra={"operation": "put_item", "error": str(e)})
        raise DataStoreUnavailable(str(e)) from e


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
    except Exception as e:
        logger.error("dynamodb_error", extra={"operation": "delete_item", "error": str(e)})
        raise DataStoreUnavailable(str(e)) from e


# ── Middleware ────────────────────────────────────────────────────────────────
@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())
    start_time = time.time()
    response = await call_next(request)
    duration = time.time() - start_time

    response.headers["X-Request-ID"] = request_id

    # Label with the ROUTE TEMPLATE ("/api/v1/ships/{ship_id}"), never the raw path.
    # Using request.url.path made every distinct ship_id its own time series, so the
    # metric's cardinality grew with the data — the classic way to kill a Prometheus.
    # Unmatched paths collapse to one bucket so scanners probing random URLs cannot
    # inflate it either.
    route = request.scope.get("route")
    endpoint = getattr(route, "path", None) or "__unmatched__"

    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=endpoint,
        status_code=response.status_code
    ).inc()
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=endpoint
    ).observe(duration)
    logger.info("request", extra={
        "request_id": request_id,
        "method": request.method,
        "path": str(request.url.path),
        "status_code": response.status_code,
        "duration_ms": round(duration * 1000, 2),
    })
    return response


# A configured-but-unreachable datastore is a dependency failure, not a bug in the
# request. 503 with Retry-After tells the caller the truth: nothing is wrong with
# what you sent, try again shortly. A 500 would say "we have a bug".
#
# It still counts against the availability SLO, and it should. The SLI is "share of
# requests that did not get a 5xx", and from the user's side a request that failed
# because our database was down failed. The status code separates the two causes for
# whoever is debugging; it does not excuse either from the error budget.
@app.exception_handler(DataStoreUnavailable)
async def _datastore_unavailable_handler(request: Request, exc: DataStoreUnavailable):
    return JSONResponse(
        status_code=503,
        content={"detail": "Data store unavailable", "request_id": request.headers.get("X-Request-ID")},
        headers={"Retry-After": "5"},
    )


# ── Routes ────────────────────────────────────────────────────────────────────
# /health is LIVENESS: is this process alive and able to answer at all. It must not
# touch dependencies — if it did, one slow datastore would make Kubernetes restart
# every healthy replica and turn a degradation into an outage.
@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "version": os.getenv('APP_VERSION', '1.0.0'),
        "storage": "dynamodb" if (DYNAMODB_AVAILABLE and DYNAMODB_TABLE) else "local"
    }


# /ready is READINESS: can this instance actually serve traffic right now. This one
# DOES check the datastore, because a replica that cannot reach it should be removed
# from the Service endpoints rather than restarted. The previous code reported
# "healthy" and storage "dynamodb" without ever contacting DynamoDB, so the signal
# stayed green while every request failed.
_READY_CACHE: dict = {"checked_at": 0.0, "ok": False, "error": None}
READY_CACHE_TTL = float(os.getenv("READY_CACHE_TTL", "5"))


@app.get("/ready")
def readiness_check(response: Response):
    table = get_dynamodb_table()
    if table is None:
        return {"status": "ready", "storage": "local", "dependency_checked": False}

    now = time.time()
    if now - _READY_CACHE["checked_at"] > READY_CACHE_TTL:
        try:
            table.load()  # DescribeTable — cheap, and proves credentials and reachability
            _READY_CACHE.update(checked_at=now, ok=True, error=None)
        except Exception as e:
            _READY_CACHE.update(checked_at=now, ok=False, error=str(e))
            logger.error("readiness_failed", extra={"dependency": "dynamodb", "error": str(e)})

    if not _READY_CACHE["ok"]:
        # The reason is in the log line above, for operators. It is not returned:
        # this endpoint is reachable from the internet, and an AWS error message
        # names the account, the role and the table.
        response.status_code = 503
        return {"status": "not_ready", "storage": "dynamodb", "dependency_checked": True}
    return {"status": "ready", "storage": "dynamodb", "dependency_checked": True}


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


# v1 API
#
# These handlers are plain `def`, not `async def`, on purpose. The DynamoDB client
# is synchronous: it blocks the calling thread until AWS answers. Inside an
# `async def` handler that thread is the event loop itself, so one slow datastore
# call would freeze every other request in the process, /health included, and the
# container would be restarted for being "unhealthy" while it was merely waiting.
# FastAPI runs a `def` handler in a worker thread, which keeps the loop free.
@app.get("/api/v1/ships", dependencies=[Depends(verify_api_key)])
@limiter.limit("100/minute")
def list_ships(
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

    if status:
        valid_statuses = {"active", "docked", "transit"}
        if status not in valid_statuses:
            raise HTTPException(status_code=400, detail=f"status must be one of {valid_statuses}")

    # The status filter is evaluated by DynamoDB, but AFTER it has read the items
    # (see the note on scan above), and the page is then cut in memory. Fine for
    # a small table; the scalable form is a Query on an index plus a cursor.
    all_ships = db_list_ships(status=status)

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
def get_ship(request: Request, ship_id: str):
    ship = db_get_ship(ship_id)
    if not ship:
        raise HTTPException(status_code=404, detail=f"Ship {ship_id} not found")
    return ship


@app.post("/api/v1/ships", dependencies=[Depends(verify_api_key)])
@limiter.limit("30/minute")
def create_ship(request: Request, ship: ShipCreate):
    saved = db_put_ship(ship.model_dump())
    logger.info("ship_created", extra={"ship_id": saved["ship_id"]})
    return {"message": "Ship created", "ship": saved, "timestamp": datetime.now(timezone.utc).isoformat()}


@app.put("/api/v1/ships/{ship_id}", dependencies=[Depends(verify_api_key)])
@limiter.limit("30/minute")
def update_ship(request: Request, ship_id: str, updates: ShipUpdate):
    existing = db_get_ship(ship_id)
    if not existing:
        raise HTTPException(status_code=404, detail=f"Ship {ship_id} not found")
    updated = {**existing, **{k: v for k, v in updates.model_dump().items() if v is not None}}
    saved = db_put_ship(updated)
    logger.info("ship_updated", extra={"ship_id": ship_id})
    return {"message": "Ship updated", "ship": saved, "timestamp": datetime.now(timezone.utc).isoformat()}


@app.delete("/api/v1/ships/{ship_id}", dependencies=[Depends(verify_api_key)])
@limiter.limit("30/minute")
def delete_ship(request: Request, ship_id: str):
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
    <h1>ObserveOps <span class="badge">{environment}</span></h1>
    <p class="subtitle">Monitoring and reliability platform · AWS · Terraform · Docker · Prometheus · Grafana · Loki · AI incident diagnosis</p>

    <div class="grid">
      <div class="card">
        <h3>Services</h3>
        <div class="status-row"><span>SecureShip API</span><span style="color:#8b949e">/api/v1/ships</span></div>
        <div class="status-row"><span>StatusService</span><span style="color:#8b949e">/status/</span></div>
        <div class="status-row"><span>RAGService (AI)</span><span style="color:#8b949e">/ai/query</span></div>
      </div>
      <div class="card">
        <h3>Infrastructure</h3>
        <div class="status-row"><span>Storage</span><span style="color:#3fb950">{storage}</span></div>
        <div class="status-row"><span>Environment</span><span style="color:#3fb950">{environment}</span></div>
        <div class="status-row"><span>Version</span><span style="color:#8b949e">{version}</span></div>
      </div>
      <div class="card">
        <h3>Observability</h3>
        <div class="status-row"><span>Prometheus</span><span style="color:#8b949e">/prometheus/</span></div>
        <div class="status-row"><span>Grafana</span><span style="color:#8b949e">/grafana/</span></div>
        <div class="status-row"><span>Live status</span><span style="color:#8b949e">see Grafana, not this page</span></div>
      </div>
    </div>

    <div class="arch">
      <h3>Architecture</h3>
      <pre>
  Internet → <span class="hl">ALB</span> (public subnets) → nginx on the app server
                                                  │
              ┌─────────────────────────────────────┤
              │                                     │
      <span class="grn">EC2: App Server</span>                  <span class="grn">EC2: Observability</span>
      nginx (rate limiting)            Prometheus · Grafana
      secureship   :8001               Loki · AlertManager
      statusservice:8002                     │
      ragservice   :8003        alerts → AlertManager → LLM autopilot → Slack
              │                         audit: CloudTrail → EventBridge → <span class="hl">Lambda</span> → Slack
              └→ <span class="hl">DynamoDB</span> (ships table)

  CI/CD: GitHub Actions → ECR → SSM deploy → smoke tests → rollback
  Kubernetes: manifests and ArgoCD app-of-apps are defined in the repo; production runs on EC2 + Docker Compose
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
