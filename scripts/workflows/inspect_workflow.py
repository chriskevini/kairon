#!/usr/bin/env python3
"""
inspect_workflow.py - Inspect n8n workflow structure and node details

Usage:
    ./inspect_workflow.py workflow.json              # Show workflow overview
    ./inspect_workflow.py workflow.json --nodes      # List all nodes
    ./inspect_workflow.py workflow.json --node "Name" # Show specific node details
    ./inspect_workflow.py workflow.json --code       # Show all Code node contents
    ./inspect_workflow.py workflow.json --connections # Show connection graph
    ./inspect_workflow.py workflow.json --find "pattern" # Find nodes/code matching pattern

Examples:
    ./inspect_workflow.py n8n-workflows/Execute_Command.json --node "Validate Get"
    ./inspect_workflow.py n8n-workflows/Route_Message.json --code
    ./inspect_workflow.py n8n-workflows/*.json --find "ctx.event"
"""

import json
import sys
import os
import re
from pathlib import Path
from typing import Optional

# ANSI colors
RED = '\033[0;31m'
YELLOW = '\033[0;33m'
GREEN = '\033[0;32m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
MAGENTA = '\033[0;35m'
NC = '\033[0m'  # No Color
BOLD = '\033[1m'


def load_workflow(filepath: str) -> Optional[dict]:
    """Load a workflow from file"""
    try:
        with open(filepath, 'r') as f:
            return json.load(f)
    except (json.JSONDecodeError, FileNotFoundError) as e:
        print(f"{RED}Error loading {filepath}: {e}{NC}")
        return None


def get_node_type(node: dict) -> str:
    """Get the simplified node type"""
    full_type = node.get('type', '')
    return full_type.split('.')[-1] if '.' in full_type else full_type


def show_overview(workflow: dict, filepath: str):
    """Show workflow overview"""
    nodes = workflow.get('nodes', [])
    connections = workflow.get('connections', {})
    
    print(f"\n{CYAN}{'='*60}{NC}")
    print(f"{BOLD}Workflow: {BLUE}{workflow.get('name', os.path.basename(filepath))}{NC}")
    print(f"{CYAN}{'='*60}{NC}")
    
    # Count node types
    type_counts = {}
    for node in nodes:
        node_type = get_node_type(node)
        type_counts[node_type] = type_counts.get(node_type, 0) + 1
    
    print(f"\n{BOLD}Summary:{NC}")
    print(f"  Total nodes: {len(nodes)}")
    print(f"  Connections: {sum(len(v.get('main', [])) for v in connections.values())}")
    
    print(f"\n{BOLD}Node types:{NC}")
    for node_type, count in sorted(type_counts.items(), key=lambda x: -x[1]):
        print(f"  {node_type}: {count}")
    
    # Find entry points (trigger nodes)
    triggers = [n for n in nodes if any(t in n.get('type', '') for t in 
                ['webhook', 'Trigger', 'manualTrigger', 'schedule'])]
    if triggers:
        print(f"\n{BOLD}Entry points:{NC}")
        for t in triggers:
            print(f"  {GREEN}→{NC} {t.get('name')} ({get_node_type(t)})")
    
    # Find exit points (nodes with no outgoing connections)
    connected_sources = set(connections.keys())
    exit_nodes = [n for n in nodes if n.get('name') not in connected_sources]
    if exit_nodes:
        print(f"\n{BOLD}Exit points:{NC}")
        for e in exit_nodes[:5]:
            print(f"  {RED}←{NC} {e.get('name')} ({get_node_type(e)})")
        if len(exit_nodes) > 5:
            print(f"  ... and {len(exit_nodes) - 5} more")


def list_nodes(workflow: dict):
    """List all nodes with their types"""
    nodes = workflow.get('nodes', [])
    
    print(f"\n{BOLD}Nodes ({len(nodes)}):{NC}\n")
    
    # Group by type
    by_type = {}
    for node in nodes:
        node_type = get_node_type(node)
        if node_type not in by_type:
            by_type[node_type] = []
        by_type[node_type].append(node.get('name'))
    
    for node_type in sorted(by_type.keys()):
        print(f"{CYAN}{node_type}:{NC}")
        for name in sorted(by_type[node_type]):
            print(f"  • {name}")
        print()


def show_node(workflow: dict, node_name: str):
    """Show details of a specific node"""
    nodes = workflow.get('nodes', [])
    node = None
    for n in nodes:
        if n.get('name') == node_name:
            node = n
            break
    
    if not node:
        print(f"{RED}Node '{node_name}' not found{NC}")
        print(f"\nAvailable nodes:")
        for n in sorted(nodes, key=lambda x: x.get('name', '')):
            print(f"  • {n.get('name')}")
        return
    
    print(f"\n{CYAN}{'='*60}{NC}")
    print(f"{BOLD}Node: {BLUE}{node_name}{NC}")
    print(f"{CYAN}{'='*60}{NC}")
    
    print(f"\n{BOLD}Type:{NC} {node.get('type')}")
    print(f"{BOLD}ID:{NC} {node.get('id')}")
    print(f"{BOLD}Position:{NC} {node.get('position')}")
    
    params = node.get('parameters', {})
    if params:
        print(f"\n{BOLD}Parameters:{NC}")
        
        # Special handling for code nodes
        if 'jsCode' in params:
            print(f"\n{YELLOW}jsCode:{NC}")
            print(f"{MAGENTA}{'─'*40}{NC}")
            print(params['jsCode'])
            print(f"{MAGENTA}{'─'*40}{NC}")
        
        # Special handling for query nodes
        if 'query' in params:
            print(f"\n{YELLOW}query:{NC}")
            print(f"{MAGENTA}{'─'*40}{NC}")
            print(params['query'])
            print(f"{MAGENTA}{'─'*40}{NC}")
        
        # Show other parameters
        for key, value in params.items():
            if key not in ['jsCode', 'query']:
                if isinstance(value, dict):
                    print(f"\n{YELLOW}{key}:{NC}")
                    print(json.dumps(value, indent=2))
                elif isinstance(value, str) and len(value) > 100:
                    print(f"\n{YELLOW}{key}:{NC} {value[:100]}...")
                else:
                    print(f"{YELLOW}{key}:{NC} {value}")
    
    # Show connections
    connections = workflow.get('connections', {})
    
    # Incoming connections
    incoming = []
    for source, conns in connections.items():
        for main_conns in conns.get('main', []):
            for conn in main_conns:
                if conn.get('node') == node_name:
                    incoming.append(source)
    
    if incoming:
        print(f"\n{BOLD}Incoming from:{NC}")
        for src in incoming:
            print(f"  {GREEN}←{NC} {src}")
    
    # Outgoing connections
    if node_name in connections:
        print(f"\n{BOLD}Outgoing to:{NC}")
        for i, main_conns in enumerate(connections[node_name].get('main', [])):
            for conn in main_conns:
                output_label = f"[output {i}]" if i > 0 else ""
                print(f"  {RED}→{NC} {conn.get('node')} {output_label}")


def show_all_code(workflow: dict):
    """Show all Code node contents"""
    nodes = workflow.get('nodes', [])
    code_nodes = [n for n in nodes if get_node_type(n) == 'code']
    
    if not code_nodes:
        print(f"{YELLOW}No Code nodes found{NC}")
        return
    
    print(f"\n{BOLD}Code Nodes ({len(code_nodes)}):{NC}")
    
    for node in sorted(code_nodes, key=lambda x: x.get('name', '')):
        name = node.get('name')
        code = node.get('parameters', {}).get('jsCode', '')
        
        print(f"\n{CYAN}{'='*60}{NC}")
        print(f"{BLUE}{name}{NC}")
        print(f"{CYAN}{'='*60}{NC}")
        print(code)


def show_connections(workflow: dict):
    """Show connection graph"""
    connections = workflow.get('connections', {})
    nodes = workflow.get('nodes', [])
    
    # Build adjacency list
    graph = {}
    for source, conns in connections.items():
        if source not in graph:
            graph[source] = []
        for main_conns in conns.get('main', []):
            for conn in main_conns:
                graph[source].append(conn.get('node'))
    
    print(f"\n{BOLD}Connection Graph:{NC}\n")
    
    # Find roots (nodes with no incoming connections)
    all_targets = set()
    for targets in graph.values():
        all_targets.update(targets)
    
    roots = [n.get('name') for n in nodes if n.get('name') not in all_targets]
    
    def print_tree(node_name: str, indent: int = 0, visited: Optional[set] = None):
        if visited is None:
            visited = set()
        
        prefix = "  " * indent
        if node_name in visited:
            print(f"{prefix}{YELLOW}↺ {node_name} (cycle){NC}")
            return
        
        visited.add(node_name)
        
        # Find node type
        node = next((n for n in nodes if n.get('name') == node_name), None)
        node_type = get_node_type(node) if node else "?"
        
        print(f"{prefix}{GREEN}├─{NC} {node_name} {CYAN}({node_type}){NC}")
        
        children = graph.get(node_name, [])
        for child in children:
            print_tree(child, indent + 1, visited.copy())
    
    for root in roots:
        print_tree(root)
        print()


def find_pattern(workflow: dict, pattern: str, filepath: str):
    """Find nodes/code matching a pattern"""
    nodes = workflow.get('nodes', [])
    regex = re.compile(pattern, re.IGNORECASE)
    matches = []
    
    for node in nodes:
        name = node.get('name', '')
        
        # Check node name
        if regex.search(name):
            matches.append((name, 'name', name))
        
        # Check code
        code = node.get('parameters', {}).get('jsCode', '')
        if code:
            for i, line in enumerate(code.split('\n'), 1):
                if regex.search(line):
                    matches.append((name, f'code line {i}', line.strip()))
        
        # Check query
        query = node.get('parameters', {}).get('query', '')
        if query and regex.search(query):
            matches.append((name, 'query', query[:100]))
        
        # Check queryReplacement
        qr = node.get('parameters', {}).get('options', {}).get('queryReplacement', '')
        if qr and regex.search(qr):
            matches.append((name, 'queryReplacement', qr[:100]))
    
    if matches:
        print(f"\n{GREEN}Found {len(matches)} match(es) for '{pattern}' in {os.path.basename(filepath)}:{NC}\n")
        for node_name, location, content in matches:
            print(f"  {BLUE}{node_name}{NC} ({location}):")
            print(f"    {content[:80]}{'...' if len(content) > 80 else ''}")
    
    return matches


def main():
    args = sys.argv[1:]
    
    if not args or args[0] in ['-h', '--help']:
        print(__doc__)
        sys.exit(0)
    
    # Parse arguments
    files = []
    command = 'overview'
    command_arg = None
    
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == '--nodes':
            command = 'nodes'
        elif arg == '--node':
            command = 'node'
            i += 1
            command_arg = args[i] if i < len(args) else None
        elif arg == '--code':
            command = 'code'
        elif arg == '--connections':
            command = 'connections'
        elif arg == '--find':
            command = 'find'
            i += 1
            command_arg = args[i] if i < len(args) else None
        elif not arg.startswith('-'):
            # Handle glob patterns
            if '*' in arg:
                files.extend(Path('.').glob(arg))
            else:
                files.append(arg)
        i += 1
    
    if not files:
        print(f"{RED}No workflow file specified{NC}")
        sys.exit(1)
    
    # Process each file
    for filepath in files:
        workflow = load_workflow(str(filepath))
        if not workflow:
            continue
        
        if command == 'overview':
            show_overview(workflow, str(filepath))
        elif command == 'nodes':
            show_overview(workflow, str(filepath))
            list_nodes(workflow)
        elif command == 'node':
            if not command_arg:
                print(f"{RED}--node requires a node name{NC}")
                sys.exit(1)
            show_node(workflow, command_arg)
        elif command == 'code':
            print(f"\n{BOLD}File: {filepath}{NC}")
            show_all_code(workflow)
        elif command == 'connections':
            show_overview(workflow, str(filepath))
            show_connections(workflow)
        elif command == 'find':
            if not command_arg:
                print(f"{RED}--find requires a pattern{NC}")
                sys.exit(1)
            find_pattern(workflow, command_arg, str(filepath))


if __name__ == '__main__':
    main()
