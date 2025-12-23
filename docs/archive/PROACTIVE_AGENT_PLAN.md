# Proactive Agent Architecture

**System:** Kairon Life-Tracking Agent  
**Stack:** n8n, PostgreSQL, Docker, OpenRouter, Python embedding sidecar  
**Status:** Active Implementation (Progress: 75%)

---

## 0. Phase 3 Design Decisions & Progress

### 1. Vector Search Orchestration
Update `embedding-service` with a `/search` endpoint to handle `pgvector` queries internally. This simplifies the n8n workflow by removing the need to handle raw vector arrays and complex SQL formatting for cosine similarity.

### 2. Context Definition (Search Query vs. Prompt Context)
*   **Search Query:** The semantic search for a technique uses a **runtime-generated summary** of the last 24h activities, recent notes, and stuck todos (see `Build Context Summary` node logic). This summary is optionally appended with the user's last message if they replied to the previous nudge.
*   **Prompt Context:** The last 3 **nudge projections** (previous agent messages) are retrieved from the database and injected into the `## Current Context` section of the final prompt. This ensures the LLM sees the conversation history without polluting the semantic search for the next coaching tool.

### 3. Selection Logic (Relevance)
Only the **single highest-relevance** coaching technique will be included in the prompt assembly. If the top semantic match score is below a defined threshold (e.g., 0.3), the system falls back to time-based (Morning/Evening) or context-triggered (Stuck Todo) modules.

### 4. Empty State Handling
If no activities, notes, or todos exist, the search query falls back to a placeholder: **"No Recently Recorded Activity"**.

### 5. Prompt Construction (Priority-Based)
The prompt is assembled by concatenating modules in priority order:
1.  **Persona (0)**: Core identity.
2.  **Technique (50)**: The single semantic match or fallback.
3.  **Context (75)**: Dynamic user data (North Star, Activities, Notes, Todos, and **Last 3 Nudges**).
4.  **Format (100)**: Response structure rules.
5.  **Guardrails (200)**: Safety and professional boundaries.

---

## 0. Current Implementation Progress (2025-12-22)

### ✅ Completed
- **Phase 1: Prompt Modules**: Table created (`prompt_modules`), initial modules seeded, and `Proactive_Agent.json` uses tag-based assembly.
- **Phase 2: Embedding Service**: Python sidecar is live, `pgvector` enabled, and `Save_Extraction` posts to the embedding service.
- **Phase 4 (Infrastructure): Intelligent Scheduling**: `next_pulse` exists in `config`, `Proactive_Agent_Cron.json` respects it, and `Route_Message.json` resets it on user activity.

### ⚠️ In Progress / Partial
- **Phase 3: Semantic Selection**: `prompt_modules` table has an `embedding` column, but the `Proactive_Agent` workflow does not yet perform vector similarity searches to select coaching techniques. It still relies on tags.
- **Phase 4 (Logic): Dynamic Scheduling**: The `Proactive_Agent` LLM prompt hasn't been fully tuned to return structured `next_pulse` values, so the cron currently falls back to a default 2-hour interval.

### 🚀 Next Steps
1. **Implement Semantic Selection**: Update `Proactive_Agent.json` to query `prompt_modules` using vector cosine similarity based on recent user activity.
2. **Tune Agent Scheduling**: Update the proactive agent's prompt to return a JSON object containing both the `message` and a calculated `next_pulse` timestamp.
3. **Automate Embedding Backfills**: Ensure the `backfill_embeddings.py` script runs periodically or after missed saves.

---

## 1. Overview

This document describes the **proactive agent** - a cron-triggered system that produces contextually relevant messages based on the user's current state. This replaces the simpler `Generate_Nudge` workflow.

**Key distinction:** This is NOT about message routing (handled by tag-based routing). This is about the agent proactively reaching out with the most useful message for any given moment.

### Architecture

```
┌─────────────┐    cron     ┌─────────────────┐
│  Scheduler  │ ──────────► │  Proactive Agent │
└─────────────┘             │    Workflow      │
                            └────────┬─────────┘
                                     │
          ┌──────────────────────────┼──────────────────────────┐
          ▼                          ▼                          ▼
┌─────────────────┐      ┌─────────────────────┐      ┌─────────────────┐
│ Prompt Assembly │      │   RAG Retrieval     │      │  LLM Generation │
│ (modules + ctx) │      │ (activities, notes) │      │   (OpenRouter)  │
└─────────────────┘      └─────────────────────┘      └─────────────────┘
          │                          │
          ▼                          ▼
┌─────────────────┐      ┌─────────────────────┐
│ prompt_modules  │      │ embedding_service   │
│    (Postgres)   │      │ (Python sidecar)    │
└─────────────────┘      └─────────────────────┘
```

---

## 2. Embedding Service

### Why Local Embeddings?

- **Cost:** No API calls for every retrieval
- **Latency:** Sub-50ms local inference vs 200-500ms API roundtrip
- **Privacy:** User data never leaves the server
- **Reliability:** No external dependency for core functionality

### Model Selection

Given 2GB RAM constraint, use `all-MiniLM-L6-v2`:

| Property | Value |
|----------|-------|
| Dimensions | 384 |
| Model size | ~80MB |
| RAM when loaded | ~200-250MB |
| Speed (CPU) | ~750 queries/sec |
| Quality (MTEB avg) | Good for semantic similarity |

This model handles both use cases:
1. **RAG retrieval** - Finding relevant activities/notes
2. **Prompt module selection** - Finding relevant coaching techniques

The quality tradeoff (~15% vs larger models) is acceptable for personal life-tracking where exact precision isn't critical.

### Service Design

Lightweight Python sidecar with FastAPI:

```python
# embedding_service.py
from fastapi import FastAPI
from sentence_transformers import SentenceTransformer
from pydantic import BaseModel
import numpy as np

app = FastAPI()
model = SentenceTransformer('all-MiniLM-L6-v2')

class EmbedRequest(BaseModel):
    texts: list[str]

class SimilarityRequest(BaseModel):
    query: str
    candidates: list[str]
    top_k: int = 3

@app.post("/embed")
def embed(req: EmbedRequest) -> list[list[float]]:
    """Generate embeddings for a list of texts."""
    embeddings = model.encode(req.texts, normalize_embeddings=True)
    return embeddings.tolist()

@app.post("/similarity")
def similarity(req: SimilarityRequest):
    """Find top-k most similar candidates to query."""
    query_emb = model.encode([req.query], normalize_embeddings=True)
    cand_embs = model.encode(req.candidates, normalize_embeddings=True)
    scores = np.dot(cand_embs, query_emb.T).flatten()
    top_indices = np.argsort(scores)[::-1][:req.top_k]
    return [{"index": int(i), "score": float(scores[i]), "text": req.candidates[i]} 
            for i in top_indices]

@app.get("/health")
def health():
    return {"status": "ok", "model": "all-MiniLM-L6-v2", "dimensions": 384}
```

### Memory Budget

| Component | RAM Usage |
|-----------|-----------|
| PostgreSQL | ~200MB |
| n8n | ~300-400MB |
| Discord relay | ~50MB |
| Embedding service | ~250MB |
| **Total** | ~800-900MB |

Leaves ~1GB headroom for OS and spikes.

### Environment Variables

```bash
# .env additions for Phase 2
EMBEDDING_SERVICE_URL=http://embedding-service:5001
EMBEDDING_MODEL=all-MiniLM-L6-v2
```

Workflows use `{{ $env.EMBEDDING_SERVICE_URL }}` following existing patterns.

### Deployment

```yaml
# docker-compose addition
embedding-service:
  build: ./embedding-service
  ports:
    - "5001:5001"
  environment:
    - MODEL_NAME=all-MiniLM-L6-v2
  restart: unless-stopped
  mem_limit: 512m
```

---

## 3. Data Schema

### Prompt Modules Table

```sql
-- Migration: 022_prompt_modules.sql
CREATE TABLE IF NOT EXISTS prompt_modules (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL UNIQUE,
  content TEXT NOT NULL,
  module_type TEXT NOT NULL,
  tags TEXT[] DEFAULT '{}',   -- For filtering: ['coaching', 'morning', 'emotional']
  priority INTEGER DEFAULT 50, -- Assembly order (lower = earlier in prompt)
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  CONSTRAINT valid_module_type CHECK (
    module_type IN ('persona', 'technique', 'guardrail', 'format', 'context')
  )
);

CREATE INDEX IF NOT EXISTS idx_prompt_modules_type ON prompt_modules(module_type);
CREATE INDEX IF NOT EXISTS idx_prompt_modules_active ON prompt_modules(active) WHERE active = true;
CREATE INDEX IF NOT EXISTS idx_prompt_modules_tags ON prompt_modules USING GIN(tags);
```

**Note:** Embedding column added in separate migration after embedding service is running.

### Vector Extension (Phase 2)

```sql
-- Migration: 023_enable_pgvector.sql
-- Prerequisites:
--   1. pgvector extension installed on PostgreSQL server
--   2. Database user has CREATE EXTENSION privilege

BEGIN;

-- Check if pgvector is available
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector') THEN
    RAISE EXCEPTION 'pgvector extension not available. Install: apt install postgresql-15-pgvector';
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS vector;

-- Add embedding column to prompt_modules
ALTER TABLE prompt_modules 
  ADD COLUMN IF NOT EXISTS embedding VECTOR(384);

CREATE INDEX IF NOT EXISTS idx_prompt_modules_embedding 
  ON prompt_modules USING ivfflat (embedding vector_cosine_ops) 
  WITH (lists = 10);

-- Add vector column to existing embeddings table
-- Note: embedding_data (JSONB) remains for metadata
ALTER TABLE embeddings 
  ADD COLUMN IF NOT EXISTS embedding VECTOR(384);

CREATE INDEX IF NOT EXISTS idx_embeddings_vector 
  ON embeddings USING ivfflat (embedding vector_cosine_ops) 
  WITH (lists = 100);

COMMIT;
```

### Why Split Migrations?

1. **prompt_modules is useful immediately** - Tag-based selection works without embeddings
2. **pgvector requires embedding service** - No point enabling vectors until generator exists
3. **Rollback isolation** - Can remove semantic selection without losing module system

---

## 4. Module Types

| Type | Purpose | When Included | Example |
|------|---------|---------------|---------|
| `persona` | Core identity | Always | "You are Kairon, a supportive life coach..." |
| `technique` | Coaching approach | Semantically selected | "Use the SMART goal framework..." |
| `guardrail` | Safety rules | Always | "Never provide medical advice..." |
| `format` | Output structure | By intent tag | "Return valid JSON..." |
| `context` | Dynamic data template | By intent tag | "Recent activities: {{activities}}" |

### Example Modules

```sql
-- Base persona (always included, priority 0)
INSERT INTO prompt_modules (name, content, module_type, priority) VALUES
('base_persona', 
 'You are Kairon, a supportive life coach. You help users track their activities, capture insights, and reflect on patterns. You are warm but direct, curious but not intrusive.',
 'persona', 0);

-- Morning check-in technique
INSERT INTO prompt_modules (name, content, module_type, tags, priority) VALUES
('technique_morning_checkin',
 'This is a morning check-in. Focus on: (1) How they slept, (2) Their top priority for today, (3) Any blockers or concerns. Keep it brief and energizing.',
 'technique', ARRAY['morning', 'proactive'], 50);

-- Emotional support technique
INSERT INTO prompt_modules (name, content, module_type, tags, priority) VALUES
('technique_empathy',
 'The user seems to be processing difficult emotions. Use active listening. Validate their feelings before offering perspective. Ask clarifying questions.',
 'technique', ARRAY['emotional', 'support'], 50);

-- Stuck todo nudge
INSERT INTO prompt_modules (name, content, module_type, tags, priority) VALUES
('technique_stuck_todo',
 'The user has todos that have been pending for a while. Gently explore what''s blocking progress. Offer to break down the task or discuss priorities.',
 'technique', ARRAY['todo', 'nudge'], 50);

-- Safety guardrail (always included, priority 200)
INSERT INTO prompt_modules (name, content, module_type, priority) VALUES
('guardrail_professional',
 'Never provide medical, legal, or financial advice. For serious concerns, suggest consulting a professional. You are a thinking partner, not an expert.',
 'guardrail', 200);
```

---

## 5. Prompt Assembly

### Audit Trail

No module versioning needed - the `traces` table stores the fully assembled prompt for every LLM call:

```sql
-- Debug unexpected agent behavior
SELECT data->>'prompt', data->>'completion', created_at
FROM traces 
WHERE step_name = 'proactive_agent'
ORDER BY created_at DESC;
```

### Assembly Flow

```
1. Get base modules (persona, guardrails) → always included
2. Get time-based modules → morning/evening techniques
3. Get context-triggered modules → stuck todos, patterns
4. Semantic selection → top-k relevant techniques by user state
5. Inject RAG context → recent activities, notes, todos
6. Assemble by priority order
```

### Pseudo-code

```javascript
async function assembleProactivePrompt(currentTime, userState) {
  const modules = [];
  
  // 1. Always include base modules
  modules.push(...await getModulesByType('persona'));
  modules.push(...await getModulesByType('guardrail'));
  
  // 2. Time-based selection
  const hour = currentTime.getHours();
  if (hour >= 6 && hour <= 9) {
    modules.push(...await getModulesByTag('morning'));
  } else if (hour >= 20 && hour <= 23) {
    modules.push(...await getModulesByTag('evening'));
  }
  
  // 3. Context-triggered modules
  if (userState.stuckTodos.length > 0) {
    modules.push(...await getModulesByTag('stuck_todo'));
  }
  
  // 4. Semantic selection based on recent activity patterns
  const recentContext = summarizeRecentActivity(userState);
  const techniques = await semanticSelectModules(recentContext, 'technique', 2);
  modules.push(...techniques);
  
  // 5. Inject RAG context
  const contextModule = buildContextModule(userState);
  modules.push(contextModule);
  
  // 6. Assemble by priority
  return modules
    .sort((a, b) => a.priority - b.priority)
    .map(m => m.content)
    .join('\n\n');
}
```

---

## 6. RAG Retrieval

### What Gets Embedded?

| Content Type | Source | Embedded Field |
|--------------|--------|----------------|
| Activities | `projections` (type='activity') | `data->>'description'` |
| Notes | `projections` (type='note') | `data->>'text'` |
| Todos | `projections` (type='todo') | `data->>'text'` |
| Prompt modules | `prompt_modules` | `content` |

### Embedding Pipeline

```
New Projection Created
        │
        ▼
┌─────────────────┐     POST /embed     ┌─────────────────┐
│  n8n Workflow   │ ─────────────────►  │ Embedding Svc   │
│  (after save)   │                     │                 │
└─────────────────┘                     └────────┬────────┘
        │                                        │
        │ INSERT embedding                       │ vector
        ▼                                        ▼
┌─────────────────────────────────────────────────────────┐
│                     PostgreSQL                          │
│  embeddings (projection_id, embedding VECTOR(384))      │
└─────────────────────────────────────────────────────────┘
```

### Retrieval Query

```sql
-- Find similar activities/notes for context
SELECT p.projection_type, p.data, e.embedding <=> $1 AS distance
FROM embeddings e
JOIN projections p ON e.projection_id = p.id
WHERE p.status IN ('auto_confirmed', 'confirmed')
  AND p.created_at > NOW() - INTERVAL '30 days'
ORDER BY e.embedding <=> $1
LIMIT 10;
```

---

## 7. Intelligent Scheduling

### Next Pulse System

The agent controls its own check-in schedule via `next_pulse`:

```javascript
// Agent response includes scheduling hint
{
  "message": "Great progress on the report! Let's check in tomorrow morning.",
  "next_pulse": "2024-12-24T09:00:00Z"
}
```

### Storage

Use existing `config` table:

```sql
INSERT INTO config (key, value) 
VALUES ('next_pulse', '2024-12-24T09:00:00Z')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
```

### Scheduling Logic

```
┌─────────────────────────────────────────────────────────────┐
│                     Cron Job (every 5 min)                  │
└─────────────────────────────────┬───────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │ SELECT value FROM config │
                    │ WHERE key = 'next_pulse' │
                    └────────────┬────────────┘
                                 │
                    ┌────────────┴────────────┐
                    ▼                         ▼
          NOW() >= next_pulse?          NOW() < next_pulse?
                    │                         │
                    ▼                         ▼
          Run Proactive Agent           Skip (wait)
                    │
                    ▼
          Agent sets new next_pulse
```

### User Message Override

When user sends a message, reset `next_pulse` to enable immediate response:

```sql
-- In Route_Message workflow, after processing
UPDATE config SET value = NOW()::text, updated_at = NOW()
WHERE key = 'next_pulse';
```

---

## 8. Implementation Phases

### Phase 1: Prompt Modules (No Embeddings)

1. Create `022_prompt_modules.sql` migration
2. Seed initial modules (persona, techniques, guardrails)
3. Implement tag-based assembly in proactive agent workflow
4. Test with deterministic module selection

**Deliverables:**
- [ ] Migration file
- [ ] Seed data SQL
- [ ] Proactive Agent workflow (replaces Generate_Nudge)

### Phase 2: Embedding Service

1. Create Python embedding service
2. Add to docker-compose
3. Create `023_enable_pgvector.sql` migration
4. Backfill embeddings for existing projections
5. Add embedding generation to save workflows

**Embedding in Save Workflows:**
- Modify `Save_Extraction` to POST to embedding service after insert
- Use fire-and-forget pattern: don't block save on embedding failure
- Log warning if embedding service is down, projection still saves

**Backfill Script:**
```bash
# scripts/db/backfill_embeddings.py
# 1. Query projections without embeddings (LEFT JOIN embeddings WHERE NULL)
# 2. Batch texts (32 at a time) to POST /embed
# 3. INSERT into embeddings table
# 4. Progress logging for large datasets
```

**Deliverables:**
- [ ] `embedding-service/` directory with Dockerfile
- [ ] Migration file
- [ ] Backfill script (`scripts/db/backfill_embeddings.py`)
- [ ] Modified Save_Extraction workflow

### Phase 3: Semantic Selection

1. Add embeddings to prompt_modules
2. Implement semantic module selection
3. Implement RAG retrieval for context
4. Tune retrieval parameters

**Deliverables:**
- [ ] Module embedding generation script
- [ ] Semantic selection in assembly logic
- [ ] RAG context injection

### Phase 4: Intelligent Scheduling

1. Add next_pulse to config
2. Modify cron to check next_pulse
3. Agent returns next_pulse in response
4. User messages reset next_pulse

**Cron Workflow Design:**
- n8n Cron node triggers every 5 minutes
- Query `config` for `next_pulse`
- If `NOW() >= next_pulse`: Execute Proactive Agent workflow
- Agent response includes `next_pulse` (e.g., morning → +24h, stuck todo → +2h)

**Deliverables:**
- [ ] `Proactive_Agent_Cron.json` workflow (cron trigger → check next_pulse → Execute Workflow)
- [ ] Modified `Route_Message` workflow (reset next_pulse on user message)
- [ ] Agent prompt includes scheduling logic (returns next_pulse in response)

---

## 9. Current Prompt Files

These remain for reactive workflows (user-initiated):

```
prompts/
├── multi-capture.md     # Extraction: activity, note, todo (reactive)
├── thread-agent.md      # Conversational coaching (reactive)
├── save-thread.md       # Thread summarization (reactive)
└── archive/
    └── router-agent.md  # Deprecated: replaced by tag routing
```

The proactive agent uses **database-stored modules** for flexibility. Reactive workflows can continue using static files until there's a reason to migrate them.

---

## 10. Testing Strategy

### Phase 1: Prompt Modules
- [ ] Seed initial modules via migration
- [ ] Test tag-based selection (morning, evening, stuck_todo)
- [ ] Verify priority-based assembly order
- [ ] Test active flag toggling (disabled modules excluded)

### Phase 2: Embedding Service
- [ ] Health check endpoint returns 200
- [ ] Embed single text (latency < 100ms on CPU)
- [ ] Embed batch (32 texts)
- [ ] Backfill script completes without errors
- [ ] Save workflow continues if embedding service is down

### Phase 3: Semantic Selection
- [ ] Similarity search returns reasonable matches
- [ ] Top-k parameter works correctly
- [ ] RAG retrieval respects time window (30 days)
- [ ] Assembled prompt includes retrieved context

### Phase 4: Intelligent Scheduling
- [ ] Cron respects next_pulse (skips if `NOW() < next_pulse`)
- [ ] Agent sets appropriate next_pulse values
- [ ] User message resets next_pulse to NOW()
- [ ] No duplicate messages (proper idempotency)
