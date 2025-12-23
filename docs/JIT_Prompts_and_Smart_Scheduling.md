
# JIT Modular Prompts + Intelligent Scheduling
**System:** Dynamic Life Coach Agent  
**Stack:** n8n, PostgreSQL + pgvector, Docker, Gemini 1.5

---

## 1. Concept Overview
Unlike traditional AI setups where the system prompt is a static "wall of text," this system treats the prompt as **infrastructure**. Every character of the system prompt is pulled from a database (PostgreSQL) just-in-time (JIT) based on the user's intent.

### Key Benefits
* **Zero-Redeploy Logic:** Change AI behavior by editing a DB row.
* **Token Efficiency:** Only inject instructions relevant to the current conversation.
* **Precision:** Use "Semantic Routing" to select the best coaching style for the user's mood.

---

## 2. Data Layer (PostgreSQL + pgvector)

We use a single table to store "Instruction Modules." Each module has a vector representation of its purpose.

### SQL Schema
```sql
-- Enable the vector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create the ingredient library
CREATE TABLE prompt_ingredients (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    content TEXT NOT NULL,          -- The actual text injected into the prompt
    category VARCHAR(50),           -- persona, technique, or guardrail
    embedding VECTOR(768)           -- Size for 'nomic-embed-text'
);

-- Index for sub-millisecond search
CREATE INDEX ON prompt_ingredients USING ivfflat (embedding vector_cosine_ops);
```

---

## 3. The n8n Plumbing (Orchestration)

The workflow acts as the "Assembler." It follows these steps:

1.  **Input:** Webhook/Chat Trigger receives `user_message`.
2.  **Vectorize:** Use the **Ollama Node** (nomic-embed-text) to turn `user_message` into a vector.
3.  **Route:** Use the **Postgres Vector Store Node** to perform a similarity search:
    * *Query:* `SELECT content FROM prompt_ingredients ORDER BY embedding <=> [vector] LIMIT 3;`
4.  **Assemble:** A **Code Node** merges the results:
    ```javascript
    const modules = $items("Postgres Vector Store");
    const persona = "You are Kairon, a modular Life Coach."; // Hardcoded foundation
    const instructions = modules.map(m => m.json.content).join("\n\n");
    return { combined_prompt: persona + "\n\n" + instructions };
    ```
5.  **Execute:** The **AI Agent Node** uses `{{ $json.combined_prompt }}` as the System Message.



---

## 4. Implementation: "Kairon" Life Coach Agent

### Example Seed Data
Run these to populate your "Instruction Warehouse":

```sql
INSERT INTO prompt_ingredients (name, content, category, embedding) VALUES 
('Empathy_Module', 'USER IS VULNERABLE: Use active listening. Do not give advice yet. Ask: "How does that feel in your body?"', 'technique', '[...vector...]'),
('Tough_Love', 'USER IS MAKING EXCUSES: Use the "Extreme Ownership" framework. Call out inconsistencies in their logic.', 'technique', '[...vector...]'),
('Strategy_Module', 'USER IS PLANNING: Use the SMART goal framework. Force them to define a 24-hour micro-win.', 'technique', '[...vector...]');
```

---

## 5. Docker Deployment Strategy

Host this locally to keep the "Routing" latency under 50ms.

```yaml
version: '3.8'
services:
  postgres:
    image: ankane/pgvector:latest
    environment:
      POSTGRES_DB: n8n_data
      POSTGRES_PASSWORD: password
    ports:
      - "5432:5432"

  ollama:
    image: ollama/ollama
    # Note: Ensure nomic-embed-text is pulled via: docker exec ollama ollama pull nomic-embed-text

  n8n:
    image: n8nio/n8n:latest
    ports:
      - "5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=password
```
## 6. Agent Clock Rate
Instead of running the agent with every user message or hard-coding an interval, we set a dynamic "pulse". The agent is instructed to include a next_pulse field with every response which we store to DB.  We only call the agent if current time is after this stored timestamp. A user message overwrites the next_pulse field to current time in order to keep the system feeling real-time. Benefits include more dynamic interactions, intelligent self-limiting of agent calls, and native debouncing to save compute.
