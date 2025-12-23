"""
Embedding Service for Kairon Proactive Agent
Lightweight FastAPI sidecar for local embeddings using sentence-transformers.
"""

import os
import logging
from contextlib import asynccontextmanager

import numpy as np
import psycopg2
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Model configuration
MODEL_NAME = os.getenv("EMBEDDING_MODEL", "all-MiniLM-L6-v2")
model: SentenceTransformer = None

# Database configuration
DB_HOST = os.getenv("POSTGRES_HOST", "postgres-db")
DB_NAME = os.getenv("POSTGRES_DB", "kairon")
DB_USER = os.getenv("POSTGRES_USER", "n8n_user")
DB_PASS = os.getenv("POSTGRES_PASSWORD", "password")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load model on startup."""
    global model
    logger.info(f"Loading embedding model: {MODEL_NAME}")
    model = SentenceTransformer(MODEL_NAME)
    logger.info(f"Model loaded. Dimensions: {model.get_sentence_embedding_dimension()}")
    yield
    logger.info("Shutting down embedding service")


app = FastAPI(
    title="Kairon Embedding Service",
    description="Local embeddings for RAG and semantic search",
    version="1.0.0",
    lifespan=lifespan,
)


# Request/Response models
class EmbedRequest(BaseModel):
    texts: list[str]


class EmbedResponse(BaseModel):
    embeddings: list[list[float]]
    model: str
    dimensions: int


class SimilarityRequest(BaseModel):
    query: str
    candidates: list[str]
    top_k: int = 5


class SimilarityMatch(BaseModel):
    index: int
    score: float
    text: str


class SimilarityResponse(BaseModel):
    matches: list[SimilarityMatch]
    model: str


class SearchRequest(BaseModel):
    query: str
    table: str = "prompt_modules"
    filter: dict | None = None
    top_k: int = 1


class SearchResult(BaseModel):
    id: str
    name: str | None = None
    content: str
    score: float
    metadata: dict


class SearchResponse(BaseModel):
    results: list[SearchResult]
    model: str


class HealthResponse(BaseModel):
    status: str
    model: str
    dimensions: int


@app.get("/health", response_model=HealthResponse)
def health():
    """Health check endpoint."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return HealthResponse(
        status="ok",
        model=MODEL_NAME,
        dimensions=model.get_sentence_embedding_dimension(),
    )


@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest):
    """Generate embeddings for a list of texts."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    if not req.texts:
        raise HTTPException(status_code=400, detail="No texts provided")

    if len(req.texts) > 100:
        raise HTTPException(status_code=400, detail="Maximum 100 texts per request")

    logger.info(f"Embedding {len(req.texts)} texts")
    embeddings = model.encode(req.texts, normalize_embeddings=True)

    return EmbedResponse(
        embeddings=embeddings.tolist(),
        model=MODEL_NAME,
        dimensions=model.get_sentence_embedding_dimension(),
    )


@app.post("/similarity", response_model=SimilarityResponse)
def similarity(req: SimilarityRequest):
    """Find top-k most similar candidates to query."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    if not req.candidates:
        raise HTTPException(status_code=400, detail="No candidates provided")

    if req.top_k < 1:
        raise HTTPException(status_code=400, detail="top_k must be >= 1")

    logger.info(
        f"Finding top-{req.top_k} similar from {len(req.candidates)} candidates"
    )

    # Encode query and candidates
    query_emb = model.encode([req.query], normalize_embeddings=True)
    cand_embs = model.encode(req.candidates, normalize_embeddings=True)

    # Compute cosine similarity (embeddings are normalized, so dot product = cosine)
    scores = np.dot(cand_embs, query_emb.T).flatten()

    # Get top-k indices
    top_k = min(req.top_k, len(req.candidates))
    top_indices = np.argsort(scores)[::-1][:top_k]

    matches = [
        SimilarityMatch(
            index=int(i),
            score=float(scores[i]),
            text=req.candidates[i],
        )
        for i in top_indices
    ]

    return SimilarityResponse(matches=matches, model=MODEL_NAME)


@app.post("/search", response_model=SearchResponse)
def search(req: SearchRequest):
    """Perform vector search in the database."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    logger.info(f"Searching in {req.table} for query: {req.query[:50]}...")

    # 1. Generate embedding for query
    query_embedding = model.encode([req.query], normalize_embeddings=True)[0].tolist()

    # 2. Connect to database
    try:
        conn = psycopg2.connect(
            host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASS
        )
        cur = conn.cursor()

        # 3. Construct and execute query
        # Using cosine distance (<=> operator in pgvector)
        # 1 - (embedding <=> query) = cosine similarity
        if req.table == "prompt_modules":
            sql = """
                SELECT id, name, content, 1 - (embedding <=> %s::vector) as score, 
                       jsonb_build_object('module_type', module_type, 'tags', tags, 'priority', priority) as metadata
                FROM prompt_modules
                WHERE active = true
            """
            params = [query_embedding]

            if req.filter and req.filter.get("module_type"):
                sql += " AND module_type = %s"
                params.append(req.filter["module_type"])

            sql += " ORDER BY embedding <=> %s::vector LIMIT %s"
            params.extend([query_embedding, req.top_k])

        elif req.table == "projections":
            sql = """
                SELECT p.id, NULL as name, 
                       COALESCE(p.data->>'description', p.data->>'text') as content, 
                       1 - (e.embedding <=> %s::vector) as score,
                       jsonb_build_object('projection_type', p.projection_type, 'category', p.data->>'category', 'timestamp', p.data->>'timestamp') as metadata
                FROM embeddings e
                JOIN projections p ON e.projection_id = p.id
                WHERE p.status IN ('auto_confirmed', 'confirmed')
                  AND e.embedding IS NOT NULL
            """
            params = [query_embedding]

            if req.filter and req.filter.get("projection_type"):
                sql += " AND p.projection_type = %s"
                params.append(req.filter["projection_type"])

            if req.filter and req.filter.get("days"):
                sql += " AND p.created_at > NOW() - INTERVAL '%s days'"
                params.append(req.filter["days"])

            sql += " ORDER BY e.embedding <=> %s::vector LIMIT %s"
            params.extend([query_embedding, req.top_k])
        else:
            raise HTTPException(
                status_code=400, detail=f"Unsupported table: {req.table}"
            )

        cur.execute(sql, params)
        rows = cur.fetchall()

        results = [
            SearchResult(
                id=str(row[0]),
                name=row[1],
                content=row[2],
                score=float(row[3]),
                metadata=row[4],
            )
            for row in rows
        ]

        cur.close()
        conn.close()

        return SearchResponse(results=results, model=MODEL_NAME)

    except Exception as e:
        logger.error(f"Search failed: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "5001"))
    uvicorn.run(app, host="0.0.0.0", port=port)
