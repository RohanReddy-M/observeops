"""
SecureShip API - Main Application with AI and RAG
"""
import time
import logging
import json
import os
from datetime import datetime
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_object = {"timestamp": datetime.utcnow().isoformat(), "level": record.levelname, "message": record.getMessage(), "logger": record.name}
        if hasattr(record, 'extra'):
            log_object.update(record.extra)
        return json.dumps(log_object)

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger = logging.getLogger("secureship")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

REQUEST_COUNT = Counter('http_requests_total', 'Total HTTP requests', ['method', 'endpoint', 'status_code'])
REQUEST_LATENCY = Histogram('http_request_duration_seconds', 'HTTP request latency', ['method', 'endpoint'], buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5])
APP_INFO = Gauge('app_info', 'Application information', ['version', 'environment'])
APP_INFO.labels(version=os.getenv('APP_VERSION', '1.0.0'), environment=os.getenv('ENVIRONMENT', 'local')).set(1)

app = FastAPI(title="SecureShip API", version="3.0.0")

@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    start_time = time.time()
    response = await call_next(request)
    duration = time.time() - start_time
    REQUEST_COUNT.labels(method=request.method, endpoint=request.url.path, status_code=response.status_code).inc()
    REQUEST_LATENCY.labels(method=request.method, endpoint=request.url.path).observe(duration)
    logger.info("Request processed", extra={"method": request.method, "path": str(request.url.path), "status_code": response.status_code, "duration_ms": round(duration * 1000, 2)})
    return response

SHIPS = {
    1: {"id": 1, "name": "SS Mumbai", "status": "active", "cargo": "electronics", "origin": "Mumbai", "destination": "Singapore"},
    2: {"id": 2, "name": "SS Delhi", "status": "docked", "cargo": "textiles", "origin": "Chennai", "destination": "Dubai"},
    3: {"id": 3, "name": "SS Chennai", "status": "transit", "cargo": "machinery", "origin": "Kolkata", "destination": "Rotterdam"},
}

SHIP_DOCUMENTS = [
    "SS Mumbai is an active cargo vessel carrying electronics from Mumbai to Singapore. Electronics cargo requires careful handling due to sensitivity to moisture and temperature. The Indian Ocean route has moderate piracy risk.",
    "SS Delhi is currently docked at Chennai port carrying textiles destined for Dubai. Textile cargo is low risk but requires proper stacking to prevent damage. The Arabian Sea route is generally safe.",
    "SS Chennai is in transit carrying heavy machinery from Kolkata to Rotterdam. Machinery cargo is high value and requires secure fastening. The route passes through the Suez Canal which has operational risks.",
    "Port congestion at Singapore affects electronics deliveries. Average delay is 2-3 days. Cargo insurance recommended for all electronics shipments above $100,000 value.",
    "Piracy risk in the Gulf of Aden remains elevated. All vessels transiting this area should register with MSCHOA and maintain 24-hour watch. Armed security teams are recommended.",
    "Weather advisory: Monsoon season from June to September affects Indian Ocean routes. Wave heights can reach 6 meters. All vessels should review routing during this period.",
]

vectorstore = None

def init_rag():
    global vectorstore
    try:
        from langchain_community.vectorstores import FAISS
        from langchain_community.embeddings import HuggingFaceEmbeddings
        from langchain.text_splitter import RecursiveCharacterTextSplitter
        embeddings = HuggingFaceEmbeddings(model_name="all-MiniLM-L6-v2")
        text_splitter = RecursiveCharacterTextSplitter(chunk_size=200, chunk_overlap=20)
        docs = text_splitter.create_documents(SHIP_DOCUMENTS)
        vectorstore = FAISS.from_documents(docs, embeddings)
        logger.info("RAG vectorstore initialized successfully")
    except Exception as e:
        logger.error(f"RAG init failed: {str(e)}")

@app.on_event("startup")
async def startup_event():
    init_rag()

@app.get("/health")
async def health_check():
    return {"status": "healthy", "timestamp": datetime.utcnow().isoformat(), "version": "3.0.0", "environment": os.getenv('ENVIRONMENT', 'local'), "rag_ready": vectorstore is not None}

@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/api/ships")
async def list_ships():
    return {"ships": list(SHIPS.values()), "total": len(SHIPS), "timestamp": datetime.utcnow().isoformat()}

@app.get("/api/ships/{ship_id}")
async def get_ship(ship_id: int):
    if ship_id not in SHIPS:
        return JSONResponse(status_code=404, content={"error": f"Ship {ship_id} not found"})
    return SHIPS[ship_id]

@app.post("/api/ships")
async def create_ship(request: Request):
    body = await request.json()
    return {"message": "Ship created successfully", "ship": body, "timestamp": datetime.utcnow().isoformat()}

@app.post("/api/analyze")
async def analyze_ship(request: Request):
    body = await request.json()
    ship_id = body.get("ship_id", 1)
    ship = SHIPS.get(ship_id, SHIPS[1])
    groq_api_key = os.getenv("GROQ_API_KEY")
    if not groq_api_key:
        return JSONResponse(status_code=500, content={"error": "GROQ_API_KEY not configured"})
    try:
        from groq import Groq
        client = Groq(api_key=groq_api_key)
        prompt = f"""You are a maritime risk analyst AI. Analyze this ship and provide a risk assessment.
Ship: {ship['name']}, Status: {ship['status']}, Cargo: {ship['cargo']}, Route: {ship.get('origin')} to {ship.get('destination')}
Provide: 1) Risk Level (Low/Medium/High) 2) Risk Summary (1 sentence) 3) Recommendation (1 sentence)"""
        response = client.chat.completions.create(model="llama-3.3-70b-versatile", messages=[{"role": "user", "content": prompt}], max_tokens=150, temperature=0.3)
        analysis = response.choices[0].message.content
        logger.info(f"AI analysis completed for ship {ship_id}")
        return {"ship_id": ship_id, "ship_name": ship["name"], "status": ship["status"], "cargo": ship["cargo"], "ai_analysis": analysis, "model": "llama-3.3-70b-versatile via Groq", "timestamp": datetime.utcnow().isoformat()}
    except Exception as e:
        logger.error(f"AI analysis failed: {str(e)}")
        return JSONResponse(status_code=500, content={"error": str(e)})

@app.post("/api/chat")
async def chat(request: Request):
    """
    RAG-powered chat endpoint.
    Uses LangChain + FAISS vector database to answer questions about ships.
    Demonstrates: RAG pipeline, vector database, LangChain, semantic search.
    """
    body = await request.json()
    question = body.get("question", "")
    if not question:
        return JSONResponse(status_code=400, content={"error": "question field required"})
    if vectorstore is None:
        return JSONResponse(status_code=500, content={"error": "RAG not initialized"})
    groq_api_key = os.getenv("GROQ_API_KEY")
    if not groq_api_key:
        return JSONResponse(status_code=500, content={"error": "GROQ_API_KEY not configured"})
    try:
        docs = vectorstore.similarity_search(question, k=3)
        context = "\n".join([doc.page_content for doc in docs])
        from groq import Groq
        client = Groq(api_key=groq_api_key)
        prompt = f"""You are a maritime operations assistant. Use the context below to answer the question.
Context: {context}
Question: {question}
Answer concisely based only on the context provided."""
        response = client.chat.completions.create(model="llama-3.3-70b-versatile", messages=[{"role": "user", "content": prompt}], max_tokens=200, temperature=0.3)
        answer = response.choices[0].message.content
        logger.info(f"RAG query processed: {question[:50]}")
        return {
            "question": question,
            "answer": answer,
            "sources": [doc.page_content[:100] + "..." for doc in docs],
            "model": "llama-3.3-70b-versatile via Groq",
            "retrieval": "FAISS vector similarity search",
            "timestamp": datetime.utcnow().isoformat()
        }
    except Exception as e:
        logger.error(f"RAG chat failed: {str(e)}")
        return JSONResponse(status_code=500, content={"error": str(e)})

@app.get("/")
async def root():
    return {"service": "SecureShip API", "status": "running", "version": "3.0.0", "endpoints": {"health": "/health", "ships": "/api/ships", "ai_analysis": "POST /api/analyze", "rag_chat": "POST /api/chat"}}