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

## Next Steps

After database setup:
1. Set up Discord bot (see `docs/discord-bot-setup.md`)
2. Configure n8n workflow (see `docs/n8n-workflow-implementation.md`)
3. Run Discord relay on the server
