# Setup Instructions for Remote Server

## Prerequisites on Remote Server

- Docker with postgres-db container running
- Git installed
- SSH access

## Steps

### 1. SSH to your server

```bash
ssh your_server
```

### 2. Clone the repository

```bash
cd ~
git clone https://github.com/chriskevini/kairon.git
cd kairon
```

### 3. Run the setup script

```bash
chmod +x setup_db.sh
./setup_db.sh
```

The script will:
- ✅ Check if postgres-db container is running
- ✅ Create `kairon` database
- ✅ Run schema migration
- ✅ Load seed data
- ✅ Initialize user state (will prompt for your Discord username)
- ✅ Verify setup

### 4. Get database connection info

```bash
docker port postgres-db 5432
```

This shows the port mapping. Example output:
```
0.0.0.0:5432 -> 5432
```

This means Postgres is accessible at `localhost:5432` from the server.

### 5. For n8n connection

If n8n is:

**On the same server:**
```
Host: localhost
Port: 5432
Database: kairon
User: postgres
Password: (your postgres password)
```

**On a different server:**
You'll need to:
1. Expose Postgres port securely (use SSH tunnel or VPN)
2. Or run n8n on the same server

**Connection string format:**
```
postgresql://postgres:password@localhost:5432/kairon
```

## n8n Postgres Credential Settings

When creating/updating Postgres credentials in n8n for the Kairon database:

| Setting | Value | Notes |
|---------|-------|-------|
| Host | `postgres` | Network alias, NOT container name |
| Port | `5432` | Default |
| Database | `kairon` | NOT `n8n_chat_memory` (that's n8n's internal DB) |
| User | `n8n_user` | |
| Password | `password` | Change in production |
| SSL | **Disable** | pgvector image doesn't support SSL by default |

> **Important:** There are two databases on the same postgres instance:
> - `n8n_chat_memory` - n8n's internal data (credentials, workflows, executions)
> - `kairon` - Kairon application data (events, threads, todos, etc.)
>
> Kairon workflows must use the `kairon` database, not `n8n_chat_memory`.

### Verifying Credentials

Run the verification script to check n8n can connect to postgres:

```bash
./scripts/verify_n8n_credentials.sh
```

### Emergency Credential Fix

If credentials break (e.g., after container recreation), see:
- `postmortem-2025-12-22-postgres-migration.md` for detailed recovery steps
- Quick fix: Create new credential in n8n UI, then update workflows via SQL

## Troubleshooting

### Script fails: "Container not running"

Check container:
```bash
docker ps -a | grep postgres
```

If stopped, start it:
```bash
docker start postgres-db
```

### Permission denied

Check Docker socket permissions:
```bash
sudo usermod -aG docker $USER
# Then logout and login again
```

Or run with sudo:
```bash
sudo ./setup_db.sh
```

### Database already exists

The script will prompt to drop and recreate. Or manually:
```bash
docker exec -i postgres-db psql -U postgres -c "DROP DATABASE kairon;"
docker exec -i postgres-db psql -U postgres -c "CREATE DATABASE kairon;"
```

### Need to check what's in the database

```bash
# Connect to database
docker exec -it postgres-db psql -U postgres -d kairon

# List tables
\dt

# Check data
SELECT * FROM activity_categories;
SELECT * FROM user_state;

# Exit
\q
```

### Need to reset everything

```bash
docker exec -i postgres-db psql -U postgres -c "DROP DATABASE IF EXISTS kairon;"
./setup_db.sh
```

## Manual Setup (if script doesn't work)

### 1. Create database

```bash
docker exec -i postgres-db psql -U postgres -c "CREATE DATABASE kairon;"
```

### 2. Run migration

```bash
docker exec -i postgres-db psql -U postgres -d kairon < db/migrations/001_initial_schema.sql
```

### 3. Run seeds

```bash
docker exec -i postgres-db psql -U postgres -d kairon < db/seeds/001_initial_data.sql
```

### 4. Set user state

```bash
docker exec -i postgres-db psql -U postgres -d kairon <<EOF
INSERT INTO user_state (user_login, sleeping, last_observation_at) 
VALUES ('your_discord_username', false, NULL);
EOF
```

## Docker Container Commands

### Production Postgres (postgres-db)

```bash
docker run -d \
  --name postgres-db \
  --network n8n-docker-caddy_default \
  --network-alias postgres \
  -p 5432:5432 \
  -v n8n-docker-caddy_postgres_data:/var/lib/postgresql/data \
  -e POSTGRES_USER=n8n_user \
  -e "POSTGRES_PASSWORD=password" \
  -e POSTGRES_DB=n8n_chat_memory \
  --restart unless-stopped \
  pgvector/pgvector:pg15
```

**Important:** The `--network-alias postgres` is required because n8n is configured to connect to hostname `postgres`.

### Dev Postgres (postgres-dev)

```bash
docker run -d \
  --name postgres-dev \
  --network n8n-docker-caddy_kairon-dev \
  -v n8n-docker-caddy_postgres_dev_data:/var/lib/postgresql/data \
  -v /opt/n8n-docker-caddy/seeds:/docker-entrypoint-initdb.d \
  -e POSTGRES_USER=n8n_user \
  -e POSTGRES_PASSWORD=dev_pass \
  -e POSTGRES_DB=kairon_dev \
  --restart unless-stopped \
  pgvector/pgvector:pg15
```

### Embedding Service

```bash
docker run -d \
  --name embedding-service \
  --network n8n-docker-caddy_default \
  -p 5001:5001 \
  --restart unless-stopped \
  kairon-embedding-service
```

## Next Steps

After database setup:
1. Set up Discord bot (see `docs/discord-bot-setup.md`)
2. Configure n8n workflow (see `docs/n8n-workflow-implementation.md`)
3. Run Discord relay on the server
