# SSH Script Optimization Quick Reference

## For Agents: What You Need to Know

### The Problem
SSH rate-limiting was causing issues when agents needed to update the server frequently.

### The Solution
Two-pronged approach:
1. **Fewer connections** - Batched operations into single SSH sessions
2. **Connection reuse** - ControlMaster multiplexing shares TCP connections

### What Changed

#### Scripts Are Faster & More Reliable
All SSH scripts automatically benefit from:
- Reduced connection overhead
- Better rate-limit tolerance
- Compressed file transfers (tar instead of scp)

#### No Changes Needed to Your Workflow
Everything works the same way:
```bash
./scripts/workflows/n8n-pull.sh            # Pull workflows
./scripts/workflows/n8n-push.sh            # Push workflows
./scripts/workflows/n8n-push.sh --dry-run  # Preview changes
./scripts/db/run-migration.sh 006          # Run migration
./scripts/db/db-query.sh "SELECT ..."      # Query database
```

### Technical Details (If You're Curious)

#### Connection Counts
| Script | Before | After | Improvement |
|--------|--------|-------|-------------|
| n8n-push.sh | 4 | 3 | 25% fewer |
| n8n-pull.sh | 4 | 2 | 50% fewer |
| run-migration.sh | 2 | 1 | 50% fewer |

#### ControlMaster Magic
- First SSH command creates a master connection
- Subsequent commands (within 5 minutes) reuse it
- No new TCP handshakes = no rate-limiting
- Automatic cleanup after 5 minutes of inactivity

#### File Transfer Optimization
Old way:
```bash
ssh remote "mkdir -p /tmp/dir"  # Connection 1
scp files remote:/tmp/dir/       # Connection 2
```

New way:
```bash
tar czf - files | ssh remote "mkdir -p /tmp/dir && tar xzf -"  # Single connection
```

Benefits: Faster, compressed, atomic

### Troubleshooting

#### If rate-limiting still occurs
```bash
# Check active ControlMaster connections
ls -la ~/.ssh/control/

# Manually close master connection
ssh -O exit -o ControlPath=~/.ssh/control/%r@%h:%p $REMOTE_HOST
```

#### If scripts behave unexpectedly
1. Check `.env` file has correct `REMOTE_HOST`
2. Verify SSH key authentication is working: `ssh $REMOTE_HOST echo "OK"`
3. Test without ControlMaster: `SSH_OPTIONS="" ./scripts/workflows/n8n-pull.sh`

#### Connection reuse not working
ControlMaster requires:
- SSH 4.0+ (all modern systems have this)
- Write access to `~/.ssh/control/` directory
- No conflicting SSH config settings

The scripts gracefully fall back if ControlMaster isn't available.

### For Script Developers

#### Adding SSH to a new script
```bash
#!/bin/bash
set -e

# Source SSH connection reuse setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../ssh-setup.sh" 2>/dev/null || true

# ... rest of your script ...
# All ssh/scp commands will automatically use ControlMaster
```

#### Batching operations
```bash
# Bad: Multiple SSH calls
ssh remote "command1"
ssh remote "command2"
ssh remote "command3"

# Good: Single SSH call (even with ControlMaster)
ssh remote "
    command1 && \
    command2 && \
    command3
"
```

#### Using tar pipes
```bash
# Upload multiple files
tar czf - file1 file2 dir/ | ssh remote "cd /dest && tar xzf -"

# Download multiple files
ssh remote "cd /src && tar czf - file1 file2" | tar xzf -

# Benefits: Compressed, atomic, single connection
```

### Monitoring Impact

#### Before changes
```bash
# Watch connection count during script execution
watch -n1 "ss -tn | grep ':22.*ESTAB' | wc -l"
# Typical: 4-6 connections for n8n-pull.sh
```

#### After changes
```bash
watch -n1 "ss -tn | grep ':22.*ESTAB' | wc -l"
# Typical: 1-2 connections for n8n-pull.sh
```

### See Also
- `docs/SSH_OPTIMIZATIONS.md` - Complete technical documentation
- `scripts/ssh-setup.sh` - ControlMaster implementation
- `.ssh/control/` - Active connection sockets
