# Database Setup Instructions

## Prerequisites

- PostgreSQL 14+ installed
- Access to create databases
- psql command-line tool

## Setup Steps

### 1. Create Database

```bash
createdb kairon
```

### 2. Run Migration

```bash
psql kairon < db/migrations/001_initial_schema.sql
```

### 3. Run Seeds

```bash
psql kairon < db/seeds/001_initial_data.sql
```

### 4. Set Your Discord Username

```bash
psql kairon
```

Then run:
```sql
INSERT INTO user_state (user_login, sleeping, last_observation_at) 
VALUES ('your_discord_username', false, NULL)
ON CONFLICT (user_login) DO NOTHING;
```

### 5. Verify Setup

```sql
-- Check tables
\dt

-- Check activity categories
SELECT * FROM activity_categories;

-- Check note categories
SELECT * FROM note_categories;

-- Check config
SELECT * FROM config;

-- Check user state
SELECT * FROM user_state;
```

## Database Connection String

For n8n, use connection string format:

```
postgresql://username:password@localhost:5432/kairon
```

Or configure separately:
- **Host:** localhost
- **Port:** 5432
- **Database:** kairon
- **User:** your_postgres_user
- **Password:** your_postgres_password

## Useful Queries

### Recent activities
```sql
SELECT * FROM recent_activities LIMIT 10;
```

### Recent notes
```sql
SELECT * FROM recent_notes LIMIT 10;
```

### Routing audit trail
```sql
SELECT 
  re.received_at,
  re.clean_text,
  rd.intent,
  rd.forced_by,
  rd.confidence
FROM raw_events re
JOIN routing_decisions rd ON rd.raw_event_id = re.id
ORDER BY re.received_at DESC
LIMIT 20;
```

### Thread conversations
```sql
SELECT 
  c.thread_id,
  c.topic,
  c.status,
  COUNT(cm.id) as message_count
FROM conversations c
LEFT JOIN conversation_messages cm ON cm.conversation_id = c.id
GROUP BY c.id
ORDER BY c.created_at DESC;
```

## Troubleshooting

### Reset database (WARNING: Deletes all data)

```bash
dropdb kairon
createdb kairon
psql kairon < db/migrations/001_initial_schema.sql
psql kairon < db/seeds/001_initial_data.sql
```

### Add new categories

```sql
-- Activity category
INSERT INTO activity_categories (name, is_sleep_category, sort_order)
VALUES ('new_category', false, 10);

-- Note category
INSERT INTO note_categories (name, sort_order)
VALUES ('new_category', 10);
```
