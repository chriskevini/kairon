# Database Backup and Restore System

Automated backup system for Kairon database with multi-tier rotation and off-site storage.

## Overview

The backup system provides:
- **Hourly backups** - Every hour, keeps last 24
- **Daily backups** - First backup of each day, keeps last 7
- **Weekly backups** - First backup on Sunday, keeps last 4
- **Off-site storage** - Syncs to Google Drive via rclone
- **Notifications** - Sends ntfy.sh alerts on failure
- **Easy restore** - Multiple restore options with verification

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Cron (every hour)                   │
└─────────────────────────┬───────────────────────────────┘
                          │
                          ▼
                   ┌──────────────┐
                   │  backup.sh   │
                   └──────┬───────┘
                          │
            ┌─────────────┼─────────────┐
            │             │             │
            ▼             ▼             ▼
      ┌──────────┐  ┌──────────┐  ┌──────────┐
      │  Local   │  │  Remote  │  │ Notify   │
      │  Backup  │  │  Sync    │  │ Failure   │
      └──────────┘  └──────────┘  └──────────┘
         │             │
         │             │
    hourly/ ──────────┼───────────────── Google Drive
    daily/  ──────────┘
    weekly/
```

## Requirements

### Server Requirements
- **Docker** - PostgreSQL container must be running
- **rclone** - For remote storage sync (install: `curl https://rclone.org/install.sh | sudo bash`)
- **curl** - For ntfy.sh notifications

### Configuration

Set these in `.env` file:

```bash
# Backup Configuration
BACKUP_DIR=/root/kairon-backups
RCLONE_REMOTE_NAME=gdrive
RCLONE_REMOTE_PATH=kairon-backups
NTFY_TOPIC=kairon-backups
NTFY_URL=https://ntfy.sh
BACKUP_KEEP_HOURLY=24
BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
```

### rclone Setup

Configure remote storage (Google Drive, S3, etc.):

```bash
# Create rclone config
rclone config

# Follow prompts to authenticate with your storage provider

# Test connection
rclone ls gdrive:

# Sync to remote
rclone sync /path/to/local gdrive:remote-path
```

**Example for Google Drive:**
```bash
rclone config create gdrive
# Type: drive
# Scope: drive (full access)
# Follow browser authentication flow
```

## Installation

### 1. Place Scripts

```bash
# Scripts are in repo at:
scripts/db/backup.sh
scripts/db/restore.sh

# On production server, copy to location:
mkdir -p /root/kairon-backups
cp scripts/db/backup.sh /root/kairon-backups/
cp scripts/db/restore.sh /root/kairon-backups/
chmod +x /root/kairon-backups/*.sh
```

### 2. Update .env on Server

```bash
# SSH to server
cd ~/kairon

# Copy .env.example and fill in values
cp .env.example .env
nano .env  # Add backup variables
```

### 3. Configure Cron Job

```bash
# Edit crontab
crontab -e

# Add hourly backup (every hour at 0 minutes)
0 * * * * /root/kairon-backups/backup.sh >> /root/kairon-backups/cron.log 2>&1
```

**Verify cron is running:**
```bash
# Check if backup script runs
tail -f /root/kairon-backups/cron.log

# Check recent backups
ls -lh /root/kairon-backups/hourly/
```

## Usage

### Backup (Automated)

Backups run automatically via cron. Manual backup:

```bash
cd /root/kairon-backups
./backup.sh
```

**Output:**
```
[2025-12-26 07:00:01] Starting backup...
[2025-12-26 07:00:02] Creating database dump...
[2025-12-26 07:00:03] Dump created: /root/kairon-backups/kairon_2025-12-26_07-00-01.dump (1.1M)
[2025-12-26 07:00:03] Daily backup created
[2025-12-26 07:00:03] Rotating old backups...
[2025-12-26 07:00:04] Syncing to Google Drive...
[2025-12-26 07:00:08] Backup complete! Local: 20M, Hourly: 9, Daily: 5, Weekly: 0
```

### Restore

```bash
cd /root/kairon-backups

# List all backups
./restore.sh --list

# Restore from latest hourly backup
./restore.sh --latest

# Restore from specific file
./restore.sh --file hourly/kairon_2025-12-26_05-00-01.dump

# Restore from Google Drive
./restore.sh --remote hourly/kairon_2025-12-26_05-00-01.dump

# Dry run (show what would happen)
./restore.sh --latest --dry-run

# Restore from latest daily
./restore.sh --latest-daily
```

**Restore Process:**
1. Drops connections to database
2. Drops and recreates database
3. Restores from dump file
4. Verifies tables have data
5. Reports success

## Backup Locations

### Local Structure

```
/root/kairon-backups/
├── backup.sh              # Main backup script
├── restore.sh             # Restore script
├── backup.log             # Backup execution log
├── cron.log              # Cron job log
├── hourly/               # Last 24 hourly backups
│   ├── kairon_2025-12-26_05-00-01.dump
│   ├── kairon_2025-12-26_06-00-01.dump
│   └── ...
├── daily/                # Last 7 daily backups
│   ├── kairon_2025-12-20.dump
│   ├── kairon_2025-12-21.dump
│   └── ...
└── weekly/               # Last 4 weekly backups
    ├── kairon_2024-W51.dump
    └── ...
```

### Remote Storage

Backups are synced to configured remote storage:
```
gdrive:kairon-backups/
├── hourly/
├── daily/
└── weekly/
```

**Supported providers:** Google Drive, AWS S3, Dropbox, OneDrive, etc.

## Troubleshooting

### Backup Fails: PostgreSQL Container Not Found

**Error:**
```
[ERROR] PostgreSQL container not found
```

**Solution:**
```bash
# Check if container is running
docker ps | grep postgres

# Check container name matches script (default: postgres-db)
docker ps --format "{{.Names}}"

# Update CONTAINER_DB in .env if name differs
```

### Backup Fails: rclone Not Found

**Error:**
```
ERROR: rclone sync to Google Drive failed
```

**Solution:**
```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash

# Configure remote
rclone config

# Test connection
rclone ls $RCLONE_REMOTE_NAME:
```

### Restore Fails: No Backups Found

**Error:**
```
ERROR: No hourly backups found
```

**Solution:**
```bash
# Check backup directory
ls -lh /root/kairon-backups/hourly/

# Check for recent backups
find /root/kairon-backups -name "*.dump" -mtime -1

# Check cron is running
systemctl status cron
```

### Verify Restore Worked

After restore, verify data:

```bash
# Check events
docker exec postgres-db psql -U n8n_user -d kairon \
    -c "SELECT COUNT(*) FROM events;"

# Check traces
docker exec postgres-db psql -U n8n_user -d kairon \
    -c "SELECT COUNT(*) FROM traces;"

# Check projections
docker exec postgres-db psql -U n8n_user -d kairon \
    -c "SELECT COUNT(*) FROM projections;"

# Check for orphans (events without traces)
docker exec postgres-db psql -U n8n_user -d kairon \
    -c "SELECT COUNT(*) FROM events e WHERE NOT EXISTS (SELECT 1 FROM traces t WHERE t.event_id = e.id);"
```

## Monitoring

### Check Backup Status

```bash
# View backup log
tail -50 /root/kairon-backups/backup.log

# Check cron log
tail -50 /root/kairon-backups/cron.log

# List recent backups
ls -lht /root/kairon-backups/hourly/ | head -5

# Check remote backups
rclone ls gdrive:kairon-backups/hourly/
```

### Set Up Notifications

The system uses ntfy.sh for failure notifications:

1. Create topic at https://ntfy.sh
2. Set `NTFY_TOPIC=kairon-backups` in `.env`
3. Subscribe for notifications:
   - Browser: https://ntfy.sh/kairon-backups
   - CLI: `ntfy subscribe kairon-backups`
   - Mobile: Download ntfy app

**Test notification:**
```bash
curl -d "Test notification" https://ntfy.sh/kairon-backups
```

## Disaster Recovery

### Complete Server Failure

1. **Provision new server**
2. **Install dependencies:**
   ```bash
   # Install Docker
   curl -fsSL https://get.docker.com | sh

   # Install rclone
   curl https://rclone.org/install.sh | sudo bash

   # Clone repo
   git clone https://github.com/chriskevini/kairon.git
   cd kairon
   ```
3. **Configure environment:**
   ```bash
   cp .env.example .env
   # Fill in configuration values
   ```
4. **Start services:**
   ```bash
   docker-compose up -d  # or individual docker run commands
   ```
5. **Restore from backup:**
   ```bash
   cd /root/kairon-backups
   ./restore.sh --remote hourly/kairon_2025-12-26_07-00-01.dump
   ```
6. **Verify system:**
   ```bash
   ./tools/kairon-ops.sh status
   ./tools/kairon-ops.sh verify
   ```

### Data Corruption

If database becomes corrupted:

```bash
# 1. Stop all writes (deactivate n8n workflows)

# 2. Backup corrupted database
cd /root/kairon-backups
./backup.sh

# 3. Restore from last good backup
./restore.sh --latest-daily

# 4. Verify data integrity
docker exec postgres-db psql -U n8n_user -d kairon \
    -c "SELECT COUNT(*) FROM events, traces, projections;"

# 5. Restart n8n workflows
```

## Best Practices

1. **Test restores regularly** - Don't wait for disaster to test restore
2. **Monitor notifications** - Respond quickly to backup failures
3. **Check backup age** - Ensure recent backups exist
4. **Verify off-site sync** - Confirm rclone uploads succeed
5. **Document recovery time** - Track actual RTO/RPO metrics

## Security

- **Backups not in git** - Backup scripts are in repo, but backup files are not
- **Secrets in .env** - Configuration uses environment variables, gitignored
- **Encrypted transfer** - rclone uses HTTPS for remote sync
- **Access control** - Backup directory is root-only by default

## Performance

Typical backup times for ~1.5GB database:
- **Local dump:** 10-15 seconds
- **Remote sync:** 30-60 seconds (depends on connection)
- **Total:** ~1-2 minutes

## Related Documentation

- `scripts/db/README_MIGRATION_TRACKING.md` - Database migration management
- `docs/archive/database-migration-safety.md` - Manual backup procedures
- `DEPLOYMENT_PIPELINE_AUDIT.md` - Deployment pipeline recommendations

## Support

For backup system issues:
1. Check logs in `/root/kairon-backups/backup.log`
2. Verify environment variables in `.env`
3. Test rclone connection: `rclone ls $RCLONE_REMOTE_NAME:`
4. Test PostgreSQL: `docker exec postgres-db psql -U $DB_USER -d $DB_NAME -c "SELECT 1;"`
