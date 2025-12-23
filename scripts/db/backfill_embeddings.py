#!/usr/bin/env python3
"""
Backfill embeddings for existing projections.

This script:
1. Queries all projections without embeddings
2. Batches texts to the embedding service
3. Inserts embeddings into the database

Usage:
    python backfill_embeddings.py [--embedding-url URL] [--batch-size N] [--dry-run]
"""

import argparse
import json
import logging
import sys
from urllib.request import urlopen, Request
from urllib.error import URLError

import psycopg2
from psycopg2.extras import execute_values

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def get_db_connection():
    """Get database connection from environment or defaults."""
    import os

    return psycopg2.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=os.getenv("POSTGRES_PORT", "5432"),
        dbname=os.getenv("POSTGRES_DB", "n8n_chat_memory"),
        user=os.getenv("POSTGRES_USER", "n8n_user"),
        password=os.getenv("POSTGRES_PASSWORD", "password"),
    )


def get_projections_without_embeddings(conn, limit=None):
    """Get all projections that don't have embeddings yet."""
    query = """
        SELECT 
            p.id,
            p.projection_type,
            COALESCE(p.data->>'description', p.data->>'text') as text
        FROM projections p
        LEFT JOIN embeddings e ON e.projection_id = p.id
        WHERE e.id IS NULL
          AND p.status IN ('auto_confirmed', 'confirmed')
          AND COALESCE(p.data->>'description', p.data->>'text') IS NOT NULL
          AND COALESCE(p.data->>'description', p.data->>'text') != ''
        ORDER BY p.created_at DESC
    """
    if limit:
        query += f" LIMIT {limit}"

    with conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def get_modules_without_embeddings(conn):
    """Get all prompt modules that don't have embeddings yet."""
    query = """
        SELECT id, name, content
        FROM prompt_modules
        WHERE embedding IS NULL
          AND active = true
        ORDER BY priority
    """
    with conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def embed_texts(texts, embedding_url):
    """Call embedding service to get vectors."""
    data = json.dumps({"texts": texts}).encode("utf-8")
    req = Request(
        f"{embedding_url}/embed",
        data=data,
        headers={"Content-Type": "application/json"},
    )

    try:
        with urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            return result["embeddings"]
    except URLError as e:
        logger.error(f"Failed to connect to embedding service: {e}")
        raise


def insert_projection_embeddings(conn, projection_embeddings, model_name):
    """Insert embeddings for projections."""
    if not projection_embeddings:
        return 0

    with conn.cursor() as cur:
        # Insert into embeddings table
        values = [
            (
                proj_id,
                model_name,
                "{}",  # embedding_data (legacy JSONB, keep empty)
                text,
                f"[{','.join(map(str, emb))}]",  # vector format
            )
            for proj_id, text, emb in projection_embeddings
        ]

        execute_values(
            cur,
            """
            INSERT INTO embeddings (projection_id, model, embedding_data, embedded_text, embedding)
            VALUES %s
            ON CONFLICT DO NOTHING
            """,
            values,
            template="(%s, %s, %s, %s, %s::vector)",
        )

        conn.commit()
        return cur.rowcount


def update_module_embeddings(conn, module_embeddings):
    """Update prompt_modules with embeddings."""
    if not module_embeddings:
        return 0

    with conn.cursor() as cur:
        for module_id, embedding in module_embeddings:
            vector_str = f"[{','.join(map(str, embedding))}]"
            cur.execute(
                "UPDATE prompt_modules SET embedding = %s::vector WHERE id = %s",
                (vector_str, module_id),
            )

        conn.commit()
        return len(module_embeddings)


def main():
    parser = argparse.ArgumentParser(
        description="Backfill embeddings for projections and modules"
    )
    parser.add_argument(
        "--embedding-url",
        default="http://localhost:5001",
        help="URL of embedding service (default: http://localhost:5001)",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=32,
        help="Number of texts to embed per batch (default: 32)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Limit number of projections to process (default: all)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes",
    )
    parser.add_argument(
        "--modules-only",
        action="store_true",
        help="Only backfill prompt modules, skip projections",
    )
    parser.add_argument(
        "--projections-only",
        action="store_true",
        help="Only backfill projections, skip modules",
    )
    args = parser.parse_args()

    # Check embedding service health
    try:
        with urlopen(f"{args.embedding_url}/health", timeout=5) as resp:
            health = json.loads(resp.read().decode("utf-8"))
            logger.info(
                f"Embedding service: {health['model']} ({health['dimensions']} dims)"
            )
            model_name = health["model"]
    except URLError as e:
        logger.error(
            f"Cannot connect to embedding service at {args.embedding_url}: {e}"
        )
        sys.exit(1)

    conn = get_db_connection()

    try:
        # Backfill prompt modules
        if not args.projections_only:
            modules = get_modules_without_embeddings(conn)
            logger.info(f"Found {len(modules)} prompt modules without embeddings")

            if modules and not args.dry_run:
                texts = [m[2] for m in modules]  # content
                embeddings = embed_texts(texts, args.embedding_url)
                module_embeddings = [(m[0], emb) for m, emb in zip(modules, embeddings)]
                count = update_module_embeddings(conn, module_embeddings)
                logger.info(f"Updated {count} prompt module embeddings")
            elif modules:
                logger.info(f"[DRY RUN] Would embed {len(modules)} prompt modules")

        # Backfill projections
        if not args.modules_only:
            projections = get_projections_without_embeddings(conn, args.limit)
            logger.info(f"Found {len(projections)} projections without embeddings")

            if args.dry_run:
                logger.info(
                    f"[DRY RUN] Would embed {len(projections)} projections in batches of {args.batch_size}"
                )
                return

            total_inserted = 0
            for i in range(0, len(projections), args.batch_size):
                batch = projections[i : i + args.batch_size]
                texts = [p[2] for p in batch]  # text content

                logger.info(
                    f"Embedding batch {i // args.batch_size + 1} ({len(batch)} texts)..."
                )
                embeddings = embed_texts(texts, args.embedding_url)

                projection_embeddings = [
                    (p[0], p[2], emb)  # (proj_id, text, embedding)
                    for p, emb in zip(batch, embeddings)
                ]

                count = insert_projection_embeddings(
                    conn, projection_embeddings, model_name
                )
                total_inserted += count
                logger.info(f"  Inserted {count} embeddings (total: {total_inserted})")

            logger.info(
                f"Backfill complete. Total embeddings inserted: {total_inserted}"
            )

    finally:
        conn.close()


if __name__ == "__main__":
    main()
