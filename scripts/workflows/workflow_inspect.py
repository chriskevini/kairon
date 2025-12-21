#!/usr/bin/env python3
"""
Workflow inspection and modification tool.

Usage:
    workflow_inspect.py <workflow> nodes           List all nodes
    workflow_inspect.py <workflow> node <name>     Show node details (code, params)
    workflow_inspect.py <workflow> connections     Show connection graph
    workflow_inspect.py <workflow> flow            Show execution flow
    workflow_inspect.py <workflow> validate        Validate JSON structure
    workflow_inspect.py <workflow> sql             Extract SQL queries
    workflow_inspect.py <workflow> search <term>   Search for text in code/queries

Examples:
    ./workflow_inspect.py Multi_Capture.json nodes
    ./workflow_inspect.py Multi_Capture.json node "Parse Response"
    ./workflow_inspect.py Multi_Capture.json flow
"""

import json
import sys
import re
from pathlib import Path

# ANSI colors
CYAN = '\033[0;36m'
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
RED = '\033[0;31m'
BOLD = '\033[1m'
DIM = '\033[2m'
RESET = '\033[0m'


def load_workflow(path: str) -> tuple[dict, str]:
    """Load workflow JSON, searching in n8n-workflows/ if needed."""
    p = Path(path)
    if not p.exists():
        # Try n8n-workflows directory
        alt = Path(__file__).parent.parent.parent / 'n8n-workflows' / path
        if alt.exists():
            p = alt
        elif not path.endswith('.json'):
            alt = Path(__file__).parent.parent.parent / 'n8n-workflows' / f'{path}.json'
            if alt.exists():
                p = alt
    
    if not p.exists():
        print(f"{RED}Error:{RESET} Workflow not found: {path}")
        sys.exit(1)
    
    with open(p) as f:
        return json.load(f), p.name


def cmd_nodes(wf: dict, name: str):
    """List all nodes with their types."""
    print(f"{CYAN}=== Nodes in {name} ==={RESET}\n")
    
    nodes = wf.get('nodes', [])
    
    # Group by type
    by_type = {}
    for node in nodes:
        t = node.get('type', 'unknown').split('.')[-1]
        by_type.setdefault(t, []).append(node['name'])
    
    for node_type, names in sorted(by_type.items()):
        print(f"{YELLOW}{node_type}{RESET}")
        for n in names:
            print(f"  {n}")
        print()
    
    print(f"{DIM}Total: {len(nodes)} nodes{RESET}")


def cmd_node(wf: dict, name: str, node_name: str):
    """Show details for a specific node."""
    for node in wf.get('nodes', []):
        if node['name'].lower() == node_name.lower():
            print(f"{CYAN}=== {node['name']} ==={RESET}")
            print(f"{DIM}Type:{RESET} {node.get('type', 'unknown')}")
            print(f"{DIM}ID:{RESET} {node.get('id', 'unknown')}")
            print()
            
            params = node.get('parameters', {})
            
            # Show JS code if present
            if 'jsCode' in params:
                print(f"{YELLOW}JavaScript Code:{RESET}")
                print(params['jsCode'])
                print()
            
            # Show SQL query if present
            if 'query' in params:
                print(f"{YELLOW}SQL Query:{RESET}")
                print(params['query'])
                if 'options' in params and 'queryReplacement' in params['options']:
                    print(f"\n{DIM}Parameters:{RESET} {params['options']['queryReplacement']}")
                print()
            
            # Show prompt if present (LLM nodes)
            if 'text' in params:
                print(f"{YELLOW}Prompt:{RESET}")
                text = params['text']
                if len(text) > 500:
                    print(text[:500] + f"\n{DIM}... ({len(text)} chars total){RESET}")
                else:
                    print(text)
                print()
            
            # Show other params
            other = {k: v for k, v in params.items() 
                    if k not in ['jsCode', 'query', 'text', 'options']}
            if other:
                print(f"{YELLOW}Other Parameters:{RESET}")
                print(json.dumps(other, indent=2))
            
            return
    
    print(f"{RED}Node not found:{RESET} {node_name}")
    print(f"\n{DIM}Available nodes:{RESET}")
    for node in wf.get('nodes', []):
        print(f"  {node['name']}")


def cmd_connections(wf: dict, name: str):
    """Show connection graph."""
    print(f"{CYAN}=== Connections in {name} ==={RESET}\n")
    
    conns = wf.get('connections', {})
    for src, outputs in sorted(conns.items()):
        targets = []
        for conn_type, output_list in outputs.items():
            for output in output_list:
                for conn in output:
                    targets.append(conn.get('node', '?'))
        
        if targets:
            print(f"{GREEN}{src}{RESET}")
            for t in targets:
                print(f"  → {t}")
        else:
            print(f"{DIM}{src} (no outputs){RESET}")
    print()


def cmd_flow(wf: dict, name: str):
    """Show execution flow as a simple diagram."""
    print(f"{CYAN}=== Execution Flow: {name} ==={RESET}\n")
    
    conns = wf.get('connections', {})
    nodes = {n['name'] for n in wf.get('nodes', [])}
    
    # Find entry points (nodes with no incoming connections)
    has_incoming = set()
    for outputs in conns.values():
        for conn_type, output_list in outputs.items():
            for output in output_list:
                for conn in output:
                    has_incoming.add(conn.get('node'))
    
    entry_points = nodes - has_incoming
    
    def print_flow(node: str, indent: int = 0, visited: set | None = None):
        if visited is None:
            visited = set()
        
        if node in visited:
            print("  " * indent + f"{DIM}↻ {node} (loop){RESET}")
            return
        visited.add(node)
        
        # Get targets
        targets = []
        if node in conns:
            for conn_type, output_list in conns[node].items():
                for output in output_list:
                    for conn in output:
                        targets.append(conn.get('node'))
        
        # Print this node
        prefix = "  " * indent
        if targets:
            print(f"{prefix}{GREEN}{node}{RESET}")
            for i, t in enumerate(targets):
                is_last = i == len(targets) - 1
                connector = "└─" if is_last else "├─"
                print(f"{prefix}  {connector}→ ", end="")
                print_flow(t, indent + 2, visited.copy())
        else:
            print(f"{prefix}{node} {DIM}(end){RESET}")
    
    for entry in sorted(entry_points):
        print_flow(entry)
        print()


def cmd_validate(wf: dict, name: str):
    """Validate workflow structure."""
    print(f"{CYAN}=== Validating {name} ==={RESET}\n")
    
    errors = []
    warnings = []
    
    nodes = {n['name'] for n in wf.get('nodes', [])}
    conns = wf.get('connections', {})
    
    # Check for broken connections
    for src, outputs in conns.items():
        if src not in nodes:
            errors.append(f"Connection from non-existent node: {src}")
        for conn_type, output_list in outputs.items():
            for output in output_list:
                for conn in output:
                    target = conn.get('node')
                    if target and target not in nodes:
                        errors.append(f"Connection to non-existent node: {src} → {target}")
    
    # Check for orphan nodes
    connected = set(conns.keys())
    for outputs in conns.values():
        for conn_type, output_list in outputs.items():
            for output in output_list:
                for conn in output:
                    connected.add(conn.get('node'))
    
    orphans = nodes - connected
    # Exclude trigger nodes from orphan check
    for node in wf.get('nodes', []):
        if 'trigger' in node.get('type', '').lower() and node['name'] in orphans:
            orphans.discard(node['name'])
    
    if orphans:
        warnings.append(f"Orphan nodes (not connected): {', '.join(orphans)}")
    
    # Check for ctx pattern issues
    for node in wf.get('nodes', []):
        code = node.get('parameters', {}).get('jsCode', '')
        if "$json.event_id" in code or "$json.channel_id" in code:
            warnings.append(f"Possible flat ctx access in {node['name']}")
    
    # Print results
    if errors:
        print(f"{RED}Errors:{RESET}")
        for e in errors:
            print(f"  ✗ {e}")
        print()
    
    if warnings:
        print(f"{YELLOW}Warnings:{RESET}")
        for w in warnings:
            print(f"  ! {w}")
        print()
    
    if not errors and not warnings:
        print(f"{GREEN}✓ No issues found{RESET}")
    elif not errors:
        print(f"{GREEN}✓ No errors (but {len(warnings)} warnings){RESET}")
    else:
        print(f"{RED}✗ {len(errors)} errors, {len(warnings)} warnings{RESET}")
        sys.exit(1)


def cmd_sql(wf: dict, name: str):
    """Extract all SQL queries from workflow."""
    print(f"{CYAN}=== SQL Queries in {name} ==={RESET}\n")
    
    found = False
    for node in wf.get('nodes', []):
        query = node.get('parameters', {}).get('query')
        if query:
            found = True
            print(f"{YELLOW}{node['name']}{RESET}")
            print(query)
            
            replacement = node.get('parameters', {}).get('options', {}).get('queryReplacement')
            if replacement:
                print(f"\n{DIM}Parameters: {replacement}{RESET}")
            print()
    
    if not found:
        print(f"{DIM}No SQL queries found{RESET}")


def cmd_search(wf: dict, name: str, term: str):
    """Search for text in code and queries."""
    print(f"{CYAN}=== Searching for '{term}' in {name} ==={RESET}\n")
    
    found = False
    pattern = re.compile(re.escape(term), re.IGNORECASE)
    
    for node in wf.get('nodes', []):
        matches = []
        
        # Search in JS code
        code = node.get('parameters', {}).get('jsCode', '')
        if pattern.search(code):
            matches.append(('jsCode', code))
        
        # Search in SQL
        query = node.get('parameters', {}).get('query', '')
        if pattern.search(query):
            matches.append(('query', query))
        
        # Search in prompt
        text = node.get('parameters', {}).get('text', '')
        if pattern.search(text):
            matches.append(('prompt', text))
        
        if matches:
            found = True
            print(f"{GREEN}{node['name']}{RESET}")
            for field, content in matches:
                # Find and highlight matches
                lines = content.split('\n')
                for i, line in enumerate(lines, 1):
                    if pattern.search(line):
                        highlighted = pattern.sub(f"{YELLOW}\\g<0>{RESET}", line)
                        print(f"  {DIM}{field}:{i}{RESET} {highlighted}")
            print()
    
    if not found:
        print(f"{DIM}No matches found{RESET}")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    
    workflow_path = sys.argv[1]
    command = sys.argv[2]
    
    wf, name = load_workflow(workflow_path)
    
    commands = {
        'nodes': lambda: cmd_nodes(wf, name),
        'node': lambda: cmd_node(wf, name, sys.argv[3] if len(sys.argv) > 3 else ''),
        'connections': lambda: cmd_connections(wf, name),
        'flow': lambda: cmd_flow(wf, name),
        'validate': lambda: cmd_validate(wf, name),
        'sql': lambda: cmd_sql(wf, name),
        'search': lambda: cmd_search(wf, name, sys.argv[3] if len(sys.argv) > 3 else ''),
    }
    
    if command in commands:
        commands[command]()
    else:
        print(f"{RED}Unknown command:{RESET} {command}")
        print(f"\n{DIM}Available commands: {', '.join(commands.keys())}{RESET}")
        sys.exit(1)


if __name__ == '__main__':
    main()
