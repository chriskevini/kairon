"""
Embedding Service for Kairon Proactive Agent
Lightweight FastAPI sidecar for local embeddings using sentence-transformers.
"""

import os
import logging
from contextlib import asynccontextmanager

import numpy as np
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Model configuration
MODEL_NAME = os.getenv("EMBEDDING_MODEL", "all-MiniLM-L6-v2")
model: SentenceTransformer = None


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


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "5001"))
    uvicorn.run(app, host="0.0.0.0", port=port)
