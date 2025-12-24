#!/bin/bash
# Remote operations helper - uses SSH ControlMaster to avoid rate limiting
# Usage: ./scripts/remote.sh <command>
#
# Commands:
#   status          - Check recent n8n executions
#   logs [minutes]  - Show n8n logs (default: 5 min)
#   workflow <name> - Get workflow details
#   fix <name>      - Fix Code nodes in workflow (runOnceForEachItem issues)
#   deploy <file>   - Deploy a single workflow JSON to prod
#   db <sql>        - Run SQL on kairon database

set -e

REMOTE="DigitalOcean"
SOCKET="/tmp/ssh-controlmaster-$$"
N8N_API_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIyYTg1MWEyZC1iN2U1LTRiM2MtYWVmYi02ZWFhYTc5ZTA2NTkiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwiaWF0IjoxNzY2NDgyMTA4fQ.RXx1C0vabBntIpSp0olFU9qWlQvnY_Ouw5znKVn8dtE"

# Start ControlMaster connection
start_connection() {
  if [[ ! -S "$SOCKET" ]]; then
    ssh -o ControlMaster=yes -o ControlPath="$SOCKET" -o ControlPersist=300 -fN "$REMOTE" 2>/dev/null || true
    sleep 1
  fi
}

# Run command over existing connection
run() {
  ssh -o ControlPath="$SOCKET" "$REMOTE" "$@"
}

# Cleanup on exit
cleanup() {
  ssh -o ControlPath="$SOCKET" -O exit "$REMOTE" 2>/dev/null || true
}
trap cleanup EXIT

cmd_status() {
  echo "=== Recent n8n Executions ==="
  run "docker exec postgres-db psql -U n8n_user -d n8n_chat_memory -c \"
    SELECT e.id, w.name, e.status, e.mode, e.\\\"startedAt\\\"
    FROM execution_entity e
    JOIN workflow_entity w ON e.\\\"workflowId\\\" = w.id
    WHERE e.\\\"stoppedAt\\\" > NOW() - INTERVAL '30 minutes'
    ORDER BY e.\\\"startedAt\\\" DESC
    LIMIT 15;\""
}

cmd_logs() {
  local minutes="${1:-5}"
  echo "=== n8n Logs (last ${minutes}m) ==="
  run "docker logs --since ${minutes}m n8n-docker-caddy-n8n-1 2>&1 | grep -v 'property option' | tail -50"
}

cmd_workflow() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo "Usage: $0 workflow <name>"
    echo ""
    echo "Available workflows:"
    run "curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' 'http://localhost:5678/api/v1/workflows' | jq -r '.data[].name' | sort"
    exit 1
  fi
  
  echo "=== Workflow: $name ==="
  run "curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' 'http://localhost:5678/api/v1/workflows' | \
    jq -r '.data[] | select(.name==\"$name\") | {id, name, active, updatedAt}'"
  
  echo ""
  echo "=== Code Nodes ==="
  run "curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' 'http://localhost:5678/api/v1/workflows' | \
    jq -r '.data[] | select(.name==\"$name\") | .nodes[] | select(.type==\"n8n-nodes-base.code\") | {name, mode: .parameters.mode}'"
}

cmd_fix() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo "Usage: $0 fix <workflow_name>"
    exit 1
  fi
  
  echo "=== Fixing workflow: $name ==="
  
  # Get workflow ID
  local wf_id=$(run "curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' 'http://localhost:5678/api/v1/workflows' | jq -r '.data[] | select(.name==\"$name\") | .id'")
  
  if [[ -z "$wf_id" || "$wf_id" == "null" ]]; then
    echo "Error: Workflow '$name' not found"
    exit 1
  fi
  
  echo "Workflow ID: $wf_id"
  
  # Export, fix, and re-upload
  run "
    curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' 'http://localhost:5678/api/v1/workflows/$wf_id' > /tmp/wf_backup.json
    
    # Fix: For nodes with runOnceForEachItem that use disallowed patterns,
    # change to runOnceForAllItems and fix return format
    cat /tmp/wf_backup.json | jq '
      .nodes = [.nodes[] |
        if .type == \"n8n-nodes-base.code\" and .parameters.mode == \"runOnceForEachItem\" then
          if (.parameters.jsCode | test(\"\\\$input\\\\.(first|last|all)\\\\(\")) or 
             (.parameters.jsCode | test(\"\\\$\\\\([^)]+\\\\)\\\\.item\")) then
            .parameters.mode = \"runOnceForAllItems\" |
            .parameters.jsCode = (.parameters.jsCode | 
              gsub(\"\\\$\\\\((?<n>[^)]+)\\\\)\\\\.item\"; \"\$(\(.n)).first()\") |
              gsub(\"return \\\\{\"; \"return [{\") |
              gsub(\"\\\\};\\\\s*\$\"; \"}];\") |
              gsub(\"\\\\}\\\\s*\$\"; \"}]\"))
          else . end
        else . end
      ]
    ' > /tmp/wf_fixed.json
    
    echo 'Fixed nodes:'
    diff <(cat /tmp/wf_backup.json | jq '.nodes[] | select(.type==\"n8n-nodes-base.code\") | {name, mode: .parameters.mode}') \
         <(cat /tmp/wf_fixed.json | jq '.nodes[] | select(.type==\"n8n-nodes-base.code\") | {name, mode: .parameters.mode}') || true
    
    curl -s -X PUT -H 'Content-Type: application/json' -H 'X-N8N-API-KEY: $N8N_API_KEY' \
      -d @/tmp/wf_fixed.json 'http://localhost:5678/api/v1/workflows/$wf_id' | jq '{id, name, active}'
    
    curl -s -X POST -H 'X-N8N-API-KEY: $N8N_API_KEY' \
      'http://localhost:5678/api/v1/workflows/$wf_id/activate' | jq '{active}'
  "
  
  echo ""
  echo "Done. Use '$0 status' to monitor."
}

cmd_deploy() {
  local file="$1"
  if [[ -z "$file" || ! -f "$file" ]]; then
    echo "Usage: $0 deploy <workflow.json>"
    exit 1
  fi
  
  local name=$(jq -r '.name' "$file")
  echo "=== Deploying: $name ==="
  
  # Get workflow ID
  local wf_id=$(run "curl -s -H 'X-N8N-API-KEY: $N8N_API_KEY' 'http://localhost:5678/api/v1/workflows' | jq -r '.data[] | select(.name==\"$name\") | .id'")
  
  if [[ -z "$wf_id" || "$wf_id" == "null" ]]; then
    echo "Error: Workflow '$name' not found on remote"
    exit 1
  fi
  
  echo "Workflow ID: $wf_id"
  
  # Upload
  scp -o ControlPath="$SOCKET" "$file" "$REMOTE:/tmp/deploy_workflow.json"
  run "
    curl -s -X PUT -H 'Content-Type: application/json' -H 'X-N8N-API-KEY: $N8N_API_KEY' \
      -d @/tmp/deploy_workflow.json 'http://localhost:5678/api/v1/workflows/$wf_id' | jq '{id, name, active}'
    curl -s -X POST -H 'X-N8N-API-KEY: $N8N_API_KEY' \
      'http://localhost:5678/api/v1/workflows/$wf_id/activate' | jq '{active}'
  "
}

cmd_db() {
  local sql="$1"
  if [[ -z "$sql" ]]; then
    echo "Usage: $0 db '<sql>'"
    exit 1
  fi
  run "docker exec postgres-db psql -U kairon -d kairon -c \"$sql\""
}

# Main
start_connection

case "${1:-}" in
  status) cmd_status ;;
  logs) cmd_logs "$2" ;;
  workflow) cmd_workflow "$2" ;;
  fix) cmd_fix "$2" ;;
  deploy) cmd_deploy "$2" ;;
  db) cmd_db "$2" ;;
  *)
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  status          - Check recent n8n executions"
    echo "  logs [minutes]  - Show n8n logs (default: 5 min)"
    echo "  workflow <name> - Get workflow details"
    echo "  fix <name>      - Fix Code nodes in workflow"
    echo "  deploy <file>   - Deploy a single workflow JSON"
    echo "  db '<sql>'      - Run SQL on kairon database"
    ;;
esac
