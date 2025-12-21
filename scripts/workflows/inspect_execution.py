#!/usr/bin/env python3
"""
inspect_execution.py - Inspect n8n workflow executions via API

Usage:
    ./inspect_execution.py <execution_id>           # Show execution details
    ./inspect_execution.py <execution_id> --full    # Show full data including node outputs
    ./inspect_execution.py --list [--limit N]       # List recent executions
    ./inspect_execution.py --failed [--limit N]     # List failed executions

Examples:
    ./inspect_execution.py 5089
    ./inspect_execution.py 5089 --full
    ./inspect_execution.py --list --limit 20
    ./inspect_execution.py --failed
"""

import json
import sys
import subprocess
import argparse
import os
from pathlib import Path
from datetime import datetime

def load_env():
    """Load environment variables from .env file"""
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent.parent
    env_file = repo_root / '.env'
    
    env_vars = {}
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    env_vars[key.strip()] = value.strip()
    return env_vars

def run_ssh_curl(endpoint, env_vars, method="GET"):
    """Run curl command through SSH tunnel"""
    remote_host = env_vars.get('REMOTE_HOST')
    api_key = env_vars.get('N8N_API_KEY')
    api_url = env_vars.get('N8N_API_URL', 'http://localhost:5678')
    
    if not remote_host:
        print("Error: REMOTE_HOST not set in .env", file=sys.stderr)
        sys.exit(1)
    if not api_key:
        print("Error: N8N_API_KEY not set in .env", file=sys.stderr)
        sys.exit(1)
    
    url = f"{api_url}/api/v1{endpoint}"
    # Build curl command as a single string to avoid shell quoting issues
    curl_cmd = f"curl -s -X {method} '{url}' -H 'Accept: application/json' -H 'X-N8N-API-KEY: {api_key}'"
    cmd = ["ssh", remote_host, curl_cmd]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"SSH/curl error: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    if not result.stdout:
        print("Error: Empty response from API", file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        print(f"Response: {result.stdout[:500]}", file=sys.stderr)
        sys.exit(1)

def run_ssh_multi_curl(endpoints, env_vars):
    """Run multiple curl commands in a single SSH call, return list of results"""
    remote_host = env_vars.get('REMOTE_HOST')
    api_key = env_vars.get('N8N_API_KEY')
    api_url = env_vars.get('N8N_API_URL', 'http://localhost:5678')
    
    if not remote_host:
        print("Error: REMOTE_HOST not set in .env", file=sys.stderr)
        sys.exit(1)
    if not api_key:
        print("Error: N8N_API_KEY not set in .env", file=sys.stderr)
        sys.exit(1)
    
    # Build a script that runs all curls and outputs JSON array
    curl_commands = []
    for endpoint in endpoints:
        url = f"{api_url}/api/v1{endpoint}"
        curl_commands.append(f"curl -s '{url}' -H 'Accept: application/json' -H 'X-N8N-API-KEY: {api_key}'")
    
    # Join with delimiter so we can split results
    # Use jq to wrap results in array
    script = " && echo '|||DELIM|||' && ".join(curl_commands)
    
    cmd = ["ssh", remote_host, script]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"SSH/curl error: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    if not result.stdout:
        print("Error: Empty response from API", file=sys.stderr)
        sys.exit(1)
    
    # Split results and parse each
    parts = result.stdout.split('|||DELIM|||')
    results = []
    for part in parts:
        part = part.strip()
        if part:
            try:
                results.append(json.loads(part))
            except json.JSONDecodeError as e:
                print(f"Error parsing JSON: {e}", file=sys.stderr)
                print(f"Response: {part[:500]}", file=sys.stderr)
                sys.exit(1)
    return results

def format_timestamp(ts):
    """Format ISO timestamp to readable format"""
    if not ts:
        return "N/A"
    try:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except:
        return ts

def format_duration(start, end):
    """Calculate duration between two timestamps"""
    if not start or not end:
        return "N/A"
    try:
        start_dt = datetime.fromisoformat(start.replace('Z', '+00:00'))
        end_dt = datetime.fromisoformat(end.replace('Z', '+00:00'))
        duration = (end_dt - start_dt).total_seconds()
        if duration < 1:
            return f"{duration*1000:.0f}ms"
        elif duration < 60:
            return f"{duration:.1f}s"
        else:
            return f"{duration/60:.1f}m"
    except:
        return "N/A"

def get_execution(exec_id, env_vars, include_data=False):
    """Fetch execution details"""
    endpoint = f"/executions/{exec_id}"
    if include_data:
        endpoint += "?includeData=true"
    return run_ssh_curl(endpoint, env_vars)

def list_executions(env_vars, limit=10, status=None):
    """List recent executions"""
    endpoint = f"/executions?limit={limit}"
    if status:
        endpoint += f"&status={status}"
    return run_ssh_curl(endpoint, env_vars)

def list_executions_with_names(env_vars, limit=10, status=None):
    """List executions with workflow names in a single SSH call"""
    exec_endpoint = f"/executions?limit={limit}"
    if status:
        exec_endpoint += f"&status={status}"
    
    # Fetch both in one SSH call
    results = run_ssh_multi_curl(["/workflows", exec_endpoint], env_vars)
    workflows_data, executions_data = results
    
    # Build name mapping
    workflow_names = {w['id']: w['name'] for w in workflows_data.get('data', [])}
    
    return executions_data, workflow_names

def print_execution_summary(exec_data):
    """Print execution summary"""
    print(f"\n{'='*60}")
    print(f"Execution ID: {exec_data.get('id')}")
    print(f"{'='*60}")
    print(f"Workflow:     {exec_data.get('workflowData', {}).get('name', 'Unknown')}")
    print(f"Status:       {exec_data.get('status', 'Unknown')}")
    print(f"Mode:         {exec_data.get('mode', 'Unknown')}")
    print(f"Started:      {format_timestamp(exec_data.get('startedAt'))}")
    print(f"Finished:     {format_timestamp(exec_data.get('stoppedAt'))}")
    print(f"Duration:     {format_duration(exec_data.get('startedAt'), exec_data.get('stoppedAt'))}")
    
    # Check for error
    if exec_data.get('status') == 'error':
        print(f"\n{'!'*60}")
        print("ERROR DETAILS:")
        print(f"{'!'*60}")
        
        # Try to find error in data
        data = exec_data.get('data', {})
        result_data = data.get('resultData', {})
        
        # Check lastNodeExecuted
        last_node = result_data.get('lastNodeExecuted')
        if last_node:
            print(f"Last Node:    {last_node}")
        
        # Check for top-level error in resultData
        top_error = result_data.get('error')
        if top_error:
            print(f"\nError Type:   {top_error.get('name', 'Unknown')}")
            print(f"Message:      {top_error.get('message', 'No message')}")
            if top_error.get('description'):
                print(f"Description:  {top_error.get('description')}")
            if top_error.get('stack'):
                print(f"\nStack Trace:")
                stack_lines = top_error['stack'].split('\n')[:5]
                for line in stack_lines:
                    print(f"  {line}")
        
        # Check for error in runData
        run_data = result_data.get('runData', {})
        for node_name, node_runs in run_data.items():
            for run in node_runs:
                if run.get('error'):
                    error = run['error']
                    print(f"\nNode:         {node_name}")
                    print(f"Error Type:   {error.get('name', 'Unknown')}")
                    print(f"Message:      {error.get('message', 'No message')}")
                    if error.get('description'):
                        print(f"Description:  {error.get('description')}")
                    if error.get('stack'):
                        print(f"\nStack Trace:")
                        # Show first few lines of stack
                        stack_lines = error['stack'].split('\n')[:5]
                        for line in stack_lines:
                            print(f"  {line}")

def print_node_outputs(exec_data):
    """Print node outputs for debugging"""
    data = exec_data.get('data', {})
    result_data = data.get('resultData', {})
    run_data = result_data.get('runData', {})
    
    print(f"\n{'='*60}")
    print("NODE OUTPUTS:")
    print(f"{'='*60}")
    
    for node_name, node_runs in run_data.items():
        print(f"\n--- {node_name} ---")
        for i, run in enumerate(node_runs):
            if run.get('error'):
                print(f"  [Run {i}] ERROR: {run['error'].get('message', 'Unknown error')}")
            elif run.get('data'):
                main_data = run['data'].get('main', [[]])
                if main_data and main_data[0]:
                    # Show first item's json, truncated
                    first_item = main_data[0][0] if main_data[0] else {}
                    json_data = first_item.get('json', {})
                    json_str = json.dumps(json_data, indent=2)
                    if len(json_str) > 500:
                        json_str = json_str[:500] + "\n... (truncated)"
                    print(f"  [Run {i}] Output ({len(main_data[0])} items):")
                    for line in json_str.split('\n'):
                        print(f"    {line}")
                else:
                    print(f"  [Run {i}] No output data")

def print_execution_list(executions, workflow_names=None):
    """Print list of executions"""
    if workflow_names is None:
        workflow_names = {}
    
    print(f"\n{'ID':<8} {'Status':<10} {'Workflow':<30} {'Started':<20} {'Duration':<10}")
    print("-" * 80)
    
    for ex in executions.get('data', []):
        exec_id = ex.get('id', 'N/A')
        status = ex.get('status', 'N/A')
        
        # Get workflow name from mapping, or from workflowData if present
        workflow_id = ex.get('workflowId', '')
        workflow = workflow_names.get(workflow_id) or ex.get('workflowData', {}).get('name', 'Unknown')
        workflow = workflow[:28]
        
        started = format_timestamp(ex.get('startedAt'))
        duration = format_duration(ex.get('startedAt'), ex.get('stoppedAt'))
        
        # Color status
        if status == 'error':
            status_display = f"\033[31m{status}\033[0m"
        elif status == 'success':
            status_display = f"\033[32m{status}\033[0m"
        else:
            status_display = status
        
        print(f"{exec_id:<8} {status_display:<19} {workflow:<30} {started:<20} {duration:<10}")

def main():
    parser = argparse.ArgumentParser(description='Inspect n8n workflow executions')
    parser.add_argument('execution_id', nargs='?', help='Execution ID to inspect')
    parser.add_argument('--full', action='store_true', help='Show full node outputs')
    parser.add_argument('--list', action='store_true', help='List recent executions')
    parser.add_argument('--failed', action='store_true', help='List failed executions')
    parser.add_argument('--limit', type=int, default=10, help='Number of executions to list')
    
    args = parser.parse_args()
    env_vars = load_env()
    
    if args.list:
        executions, workflow_names = list_executions_with_names(env_vars, limit=args.limit)
        print_execution_list(executions, workflow_names)
    elif args.failed:
        executions, workflow_names = list_executions_with_names(env_vars, limit=args.limit, status='error')
        print_execution_list(executions, workflow_names)
    elif args.execution_id:
        exec_data = get_execution(args.execution_id, env_vars, include_data=True)
        print_execution_summary(exec_data)
        if args.full:
            print_node_outputs(exec_data)
    else:
        parser.print_help()

if __name__ == '__main__':
    main()
